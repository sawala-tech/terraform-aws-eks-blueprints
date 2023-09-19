#!/bin/bash
#set -e
#set -x

#export ARGOCD_PWD=$(aws secretsmanager get-secret-value --secret-id argocd-admin-secret.eks-blueprint --query SecretString --output text --region eu-west-3)
#export ARGOCD_OPTS="--port-forward --port-forward-namespace argocd --grpc-web"
#argocd login --port-forward --username admin --password $ARGOCD_PWD --insecure


function delete_argocd_appset_except_pattern() {
  # List all your app to destroy
  # Get the list of ArgoCD applications and store them in an array
  #applicationsets=($(kubectl get applicationset -A -o json | jq -r '.items[] | .metadata.namespace + "/" + .metadata.name'))
  applicationsets=($(kubectl get applicationset -A -o json | jq -r '.items[] | .metadata.name'))

  # Iterate over the applications and delete them
  for app in "${applicationsets[@]}"; do
    if [[ ! "$app" =~ $1 ]]; then
      echo "Deleting applicationset: $app"
      kubectl delete ApplicationSet -n argocd $app --cascade=orphan
    else
        echo "Skipping deletion of applicationset: $app (contain '$1')"
    fi
  done

  #Wait for everything to delete
  continue_process=true
  while $continue_process; do
    # Get the list of ArgoCD applications and store them in an array
    applicationsets=($(kubectl get applicationset -A -o json | jq -r '.items[] | .metadata.name'))

    still_have_application=false
    # Iterate over the applications and delete them
    for app in "${applicationsets[@]}"; do
      if [[ ! "$app" =~ $1 ]]; then
        echo "applicationset $app still exists"
        still_have_application=true
      fi
    done
    sleep 5
    continue_process=$still_have_application
  done
  echo "No more applicationsets except $1"
}

function delete_argocd_app_except_pattern() {
  # List all your app to destroy
  # Get the list of ArgoCD applications and store them in an array
  #applications=($(argocd app list -o name))
  applications=($(kubectl get application -A -o json | jq -r '.items[] | .metadata.name'))

  # Iterate over the applications and delete them
  for app in "${applications[@]}"; do
    if [[ ! "$app" =~ $1 ]]; then
      echo "Deleting application: $app"
      kubectl -n argocd patch app $app  -p '{"metadata": {"finalizers": ["resources-finalizer.argocd.argoproj.io"]}}' --type merge
      kubectl -n argocd delete app $app    
    else
      echo "Skipping deletion of application: $app (contain '$1')"
    fi
  done

  # Wait for everything to delete
  continue_process=true
  while $continue_process; do
    # Get the list of ArgoCD applications and store them in an array
    #applications=($(argocd app list -o name))
    applications=($(kubectl get application -A -o json | jq -r '.items[] | .metadata.name'))

    still_have_application=false
    # Iterate over the applications and delete them
    for app in "${applications[@]}"; do
      if [[ ! "$app" =~ $1 ]]; then
        echo "application $app still exists"
        still_have_application=true
      fi
    done
    sleep 5
    continue_process=$still_have_application
  done
  echo "No more applications except $1"
}

#Deactivate All AppSet
delete_argocd_appset_except_pattern "^nomatch"

delete_argocd_app_except_pattern "^.*addon-|^.*argo-cd|^bootstrap-.*"

delete_argocd_app_except_pattern "^.*load-balancer|^.*external-dns|^.*argo-cd|^bootstrap-addons"

#delete_argocd_app_except_pattern "^.*load-balancer"

# #If ArgoCD namespace is stuck in terminating state, we can force it to end
export NAMESPACE=ecsdemo-crystal
kubectl get namespace $NAMESPACE -o json | jq 'del(.spec.finalizers)' > /tmp/argocd_ns.json
kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f /tmp/argocd_ns.json

echo "Tear Down Applications OK"

set +x
