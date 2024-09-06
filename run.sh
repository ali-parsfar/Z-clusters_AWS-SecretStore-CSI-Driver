#!/bin/bash
# Description = This bash script > With using awscli , eksctl , helm , kubectl , and creates a simple eks cluster with AWS SecretStore CSI Driver Provider .
# HowToUse = " % ./run.sh| tee -a output.md "
# Duration = Around 15 minutes
# Use AWS Secrets Manager secrets in Amazon Elastic Kubernetes Service = https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html
# https://github.com/aws/secrets-store-csi-driver-provider-aws/tree/main

# Note : It requires a test Secret in same account and region as EKS cluster with the name of "mysecret-SIxYX6" !

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
### Variables:
export REGION=ap-southeast-2
export CLUSTER_VER=1.29
export CLUSTER_NAME=secretstore
export CLUSTER=$CLUSTER_NAME
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ACC=$AWS_ACCOUNT_ID
export AWS_DEFAULT_REGION=$REGION



echo " 
### PARAMETERES IN USER >>> 
CLUSTER_NAME=$CLUSTER_NAME  
REGION=$REGION 
AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID

"

if [[ $1 == "cleanup" ]] ;
then 


### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " 
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 0- Cleanup IRSA file system for CA :
 "
# Do Cleanup

kubectl delete -f cluster-autoscaler-autodiscover.yaml

eksctl delete iamserviceaccount --region=ap-southeast-2 --cluster=secretstore --namespace=default --name=nginx-deployment-sa 

kubectl  -n kube-system describe sa nginx-deployment-sa

exit 1
fi;


### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo "
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 1- Create cluster "

eksctl create cluster  -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER
  region: $REGION
  version: "$CLUSTER_VER"

managedNodeGroups:
  - name: mng
    privateNetworking: true
    desiredCapacity: 2
    instanceType: t3.medium
    labels:
      worker: linux
    maxSize: 3
    minSize: 0
    volumeSize: 20
    ssh:
      allow: true
      publicKeyPath: AliSyd

kubernetesNetworkConfig:
  ipFamily: IPv4 # or IPv6

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
#  - name: aws-ebs-csi-driver

iam:
  withOIDC: true

iamIdentityMappings:
  - arn: arn:aws:iam::$ACC:user/Ali
    groups:
      - system:masters
    username: admin-Ali
  - arn: arn:aws:iam::$ACC:role/Admin
    groups:
      - system:masters
    username: isengard-Ali
    noDuplicateARNs: true # prevents shadowing of ARNs

cloudWatch:
  clusterLogging:
    enableTypes:
      - "*"

EOF

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo "
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 2- kubeconfig  : "
aws eks update-kubeconfig --name $CLUSTER --region $REGION

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " 
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
### 3- Check cluster nodes: "
kubectl get node


### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo "
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 3- create IAM Policy : 
 "

cat <<EoF > nginx-deployment-policy.json
{
    "Version": "2012-10-17",
    "Statement": [ {
        "Effect": "Allow",
        "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
        "Resource": ["arn:aws:secretsmanager:$REGION:$ACC:secret:mysecret-SIxYX6"]
    } ]
}
EoF

aws iam create-policy   \
  --policy-name nginx-deployment-policy \
  --policy-document file://nginx-deployment-policy.json




### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo "
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 4 - Install with helm  : 
 "

# Add the Secrets Store CSI Driver chart.
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws


helm install -n kube-system csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver
helm install -n kube-system secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws


# To install by using the YAML in the repo
# helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
# helm install -n kube-system csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver
# kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml





### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo "
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 5- create iamserviceaccount  : 
 "

eksctl create iamserviceaccount \
--region=$REGION \
--cluster=$CLUSTER \
--namespace=default \
--name=nginx-deployment-sa \
--attach-policy-arn=arn:aws:iam::$ACC:policy/nginx-deployment-policy \
--override-existing-serviceaccounts \
--approve

kubectl  -n kube-system describe sa nginx-deployment-sa > nginx-deployment-sa 


# eksctl delete iamserviceaccount --region=ap-southeast-2 --cluster=secretstore --namespace=default --name=nginx-deployment-sa 

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo "
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 6 - Create   SecretProviderClass Deployment and Service : 
 "

kubectl apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: nginx-deployment-aws-secrets
spec:
  provider: aws
  parameters:
    objects: |
        - objectName: "arn:aws:secretsmanager:$REGION:$ACC:secret:mysecret-SIxYX6"
        - objectName: "mysecret"
          objectType: "secretsmanager"
EOF


kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      serviceAccountName: nginx-deployment-sa
      volumes:
      - name: secrets-store-inline
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: "nginx-deployment-aws-secrets"
      containers:
      - name: nginx-deployment
        image: nginx
        command: ["sh" , "-c" , "while true ; do  date ; cat /mnt/secrets-store/mysecret ; sleep 60 ; done" ]
        ports:
        - containerPort: 80
        volumeMounts:
        - name: secrets-store-inline
          mountPath: "/mnt/secrets-store"
          readOnly: true
EOF

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo "
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 7 - recording >   logs & configs  : 
 "
 STAT=`date +%s`
 mkdir $STAT
sleep 10
cp nginx-deployment-policy $STAT
kubectl get event -A > $STAT/event.txt
kubectl describe node > $STAT/nodes.yaml
kubectl -n kube-system get pod,rs,ds,deploy,svc,sa,cm -o wide > $STAT/infra.txt
kubectl get pod -o wide -A | grep -v Running > $STAT/pod-with-issue.txt
kubectl -n kube-system get deploy,ds  -o 'custom-columns=NAME:spec.template.spec.containers[0].name,IMAGE:spec.template.spec.containers[0].image' > $STAT/images.txt
kubectl describe  SecretProviderClass -A > $STAT/SecretProviderClass.yaml
kubectl describe rs > $STAT/nginx-deployment_rs.yaml
kubectl describe pod > $STAT/nginx-deployment_pod.yaml
kubectl get crd > $STAT/crds.txt
kubectl describe sa nginx-deployment-sa > $STAT/nginx-deployment-sa 

kubectl -n kube-system get pod | grep secret
kubectl get SecretProviderClass 
kubectl get pod
kubectl logs -l app=nginx -f

