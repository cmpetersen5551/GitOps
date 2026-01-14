kubectl delete ns metallb-system 2>/dev/null
kubectl delete kustomization infrastructure-metallb infrastructure-metallb-config -n flux-system 2>/dev/null  
kubectl delete helmrelease -n metallb-system metallb 2>/dev/null
kubectl delete helmrepository -n metallb-system metallb 2>/dev/null
echo "Cleaned up"
