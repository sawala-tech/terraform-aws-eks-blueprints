#!/bin/bash

set -x

# https://docs.nvidia.com/datacenter/tesla/index.html
NVIDIA_DRIVER_VERSION="535.86.10"

# CUDA toolkit https://docs.nvidia.com/datacenter/tesla/drivers/index.html#cuda-drivers
CUDA_TOOLKIT_PACKAGE=cuda-toolkit-12-2
INSTALL_CUDA_TOOLKIT=${install_cuda_toolkit}

INSTALL_NVIDIA_CONTAINER_TOOLKIT=${install_nvidia_container_toolkit}

# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-verify.html
EFA_INSTALLER_VERSION="1.25.0"

# https://www.open-mpi.org/software/hwloc/v2.9/
MPI_HWLOC_VERSION="2.9.2"

# https://github.com/aws/aws-ofi-nccl/releases
AWS_OFI_NCCL_VERSION="1.7.1"

INSTALL_NCCL_TESTS=${install_nccl_tests}

# Remove existing NVIDIA driver if present
PACKAGE_NAME="nvidia-driver"
if yum list installed 2>/dev/null | grep -q "^$PACKAGE_NAME"; then
    yum erase -y $PACKAGE_NAME-* -q
else
    echo "$PACKAGE_NAME is not installed."
fi
rm /etc/yum.repos.d/amzn2-nvidia.rep

yum install gcc10 rsync dkms -y -q

cd /tmp

# EFA - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html
curl -s -O https://efa-installer.amazonaws.com/aws-efa-installer-$${EFA_INSTALLER_VERSION}.tar.gz
tar -xf aws-efa-installer-$${EFA_INSTALLER_VERSION}.tar.gz && cd aws-efa-installer
./efa_installer.sh -y -g
cd /tmp
rm -rf /aws-efa-installer*
# Validate
/opt/amazon/efa/bin/fi_info fi_info -p efa -t FI_EP_RDM

# NVIDIA driver
wget -q -O NVIDIA-Linux-driver.run "https://us.download.nvidia.com/tesla/$${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-$${NVIDIA_DRIVER_VERSION}.run"
CC=gcc10-cc sh NVIDIA-Linux-driver.run -q -a --ui=none
rm NVIDIA-Linux-driver.run

# Install FabricManager
curl -s -O https://developer.download.nvidia.com/compute/nvidia-driver/redist/fabricmanager/linux-x86_64/fabricmanager-linux-x86_64-$${NVIDIA_DRIVER_VERSION}-archive.tar.xz
tar -xf fabricmanager-linux-x86_64-$${NVIDIA_DRIVER_VERSION}-archive.tar.xz
rsync -al fabricmanager-linux-x86_64-$${NVIDIA_DRIVER_VERSION}-archive/ /usr/ --exclude LICENSE
mv /usr/systemd/nvidia-fabricmanager.service /usr/lib/systemd/system
systemctl enable nvidia-fabricmanager
rm -rf fabricmanager-linux*

# CUDA tooklit - can be installed on host or deployed in container
if $${INSTALL_CUDA_TOOLKIT}; then
  yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-rhel7.repo
  yum clean all -q
  yum install libglvnd-glx $${CUDA_TOOLKIT_PACKAGE} -y -q
fi

# NVIDIA container toolkit - can be installed on host or deployed in container
if $${INSTALL_NVIDIA_CONTAINER_TOOLKIT}; then
  distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
  curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.repo | tee /etc/yum.repos.d/nvidia-docker.repo
  yum install -y nvidia-container-toolkit -q
fi

# Setup EFA device plugin

# hwloc - https://www.open-mpi.org/projects/hwloc/tutorials/20120702-POA-hwloc-tutorial.html
wget -q https://download.open-mpi.org/release/hwloc/v$${MPI_HWLOC_VERSION::-2}/hwloc-$${MPI_HWLOC_VERSION}.tar.gz
tar xf hwloc-$${MPI_HWLOC_VERSION}.tar.gz && cd hwloc-$${MPI_HWLOC_VERSION}
./configure
make -s
make install -s
cd /tmp
rm -rf hwloc-$${MPI_HWLOC_VERSION}*

# aws-ofi-nccl plugin - https://github.com/aws/aws-ofi-nccl
yum install autoconf automake libtool -y -q
wget -q https://github.com/aws/aws-ofi-nccl/releases/download/v$${AWS_OFI_NCCL_VERSION}-aws/aws-ofi-nccl-$${AWS_OFI_NCCL_VERSION}-aws.tar.gz
tar xf aws-ofi-nccl-$${AWS_OFI_NCCL_VERSION}-aws.tar.gz && cd ./aws-ofi-nccl-$${AWS_OFI_NCCL_VERSION}-aws
./autogen.sh
./configure --with-libfabric=/opt/amazon/efa/ --with-cuda=/usr/local/cuda/ --with-mpi=/opt/amazon/openmpi/
make -s
make install -s
cd /tmp
rm -rf aws-ofi-nccl-$${AWS_OFI_NCCL_VERSION}*

# Setup NCCL

# NCCL https://github.com/NVIDIA/nccl
wget -q -O nccl.zip https://github.com/NVIDIA/nccl/archive/refs/heads/master.zip
unzip -qq nccl.zip && cd nccl-master
make -j src.build -s
make pkg.redhat.build -s
rpm -ivh build/pkg/rpm/x86_64/*.rpm
cd /tmp
rm -rf nccl*

# Create script that will download and execute NCCL tests when run
# This is not run during the script execution, but can be run manually afterward
cat << EOF > /opt/amazon/openmpi/nccl-tests.sh
#!/bin/bash

# Set up NCCL test https://github.com/nvidia/nccl-tests

set -x

cd tmp/
wget -q -O nccl-test.zip https://github.com/NVIDIA/nccl-tests/archive/refs/heads/master.zip
unzip nccl-test.zip && cd nccl-tests-master
make MPI=1 NCCL_HOME=/home/ec2-user/nccl-master/build MPI_HOME=/opt/amazon/openmpi/ -s

# set up environment
export EFA_HOME=/opt/amazon/efa
export MPI_HOME=/opt/amazon/openmpi
export LD_LIBRARY_PATH=$${EFA_HOME}/lib64:$${MPI_HOME}/lib64:/usr/local/lib

# Run the NCCL test
/opt/amazon/openmpi/bin/mpirunmpirun --allow-run-as-root -np 8 -bind-to none -map-by slot -x NCCL_DEBUG=INFO \
  -x LD_LIBRARY_PATH -x PATH -x FI_EFA_USE_DEVICE_RDMA=1 -x FI_EFA_FORK_SAFE=1 \
  -mca pml ob1 -mca btl ^openib ./build/all_reduce_perf -b 8 -e 2G -f 2 -t 1 -g 1 -c 1 -n 100
EOF

chmod +x /opt/amazon/openmpi/nccl-tests.sh
