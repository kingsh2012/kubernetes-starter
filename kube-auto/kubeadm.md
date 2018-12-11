# KubAdmin集群

|内网IP|节点|
|---|---|
|192.168.0.10|etcd1|
|192.168.0.8|etcd2|
|192.168.0.9|etcd3|
|192.168.0.11|k8s-master1|
|192.168.0.12|k8s-master2|
|192.168.0.13|k8s-master3|
|192.168.0.17|k8s-worker|


## 环境准备(所有节点)
```shell
# 关掉 selinux
setenforce  0
sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/sysconfig/selinux

# 关掉防火墙
systemctl stop firewalld
systemctl disable firewalld

# 设置系统运行路由转发
cat <<EOF > /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

# 生效配置
modprobe br_netfilter
sysctl -p /etc/sysctl.d/k8s.conf

# Swap分区关闭
swapoff -a
sed -ie 's/.*swap.*/#&/' /etc/fstab
```

```shell
cat > ip_list << EOF
192.168.0.14 vip
192.168.0.10 etcd1
192.168.0.8 etcd2
192.168.0.9 etcd3
192.168.0.11 k8s-master1
192.168.0.12 k8s-master2
192.168.0.13 k8s-master3
192.168.0.17 k8s-worker
EOF

cat ip_list >>/etc/hosts

# 获取主机IP
export NODE_IP=`ifconfig eth | grep netmask| awk '{print $2}'`
# 获取主机域名
export NODE_NAME=`cat ip_list | awk '$1=="'$NODE_IP'"{print $2}'`
# 获取所有ETCD主机
export ETCD_NODES=`cat ip_list | grep etcd | awk '{print $2"=https://"$1":2380"}'| xargs| sed 's/ /,/g'`
```

## 创建验证证书
```shell
wget https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
chmod +x cfssl_linux-amd64
mv cfssl_linux-amd64 /usr/local/bin/cfssl

wget https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
chmod +x cfssljson_linux-amd64
mv cfssljson_linux-amd64 /usr/local/bin/cfssljson

wget https://pkg.cfssl.org/R1.2/cfssl-certinfo_linux-amd64
chmod +x cfssl-certinfo_linux-amd64
mv cfssl-certinfo_linux-amd64 /usr/local/bin/cfssl-certinfo
```

```shell
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ],
        "expiry": "8760h"
      }
    }
  }
}
EOF
```
```
==ca-config.json==：可以定义多个 profiles，分别指定不同的过期时间、使用场景等参数；后续在签名证书时使用某个 profile；
==signing==：表示该证书可用于签名其它证书；生成的 ca.pem 证书中 CA=TRUE；
==server auth==：表示 client 可以用该 CA 对 server 提供的证书进行验证；
==client auth==：表示 server 可以用该 CA 对 client 提供的证书进行验证；
```
```shell
cat > ca-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
  {
    "C": "CN",
    "ST": "BeiJing",
    "L": "BeiJing",
    "O": "k8s",
    "OU": "System"
  }
  ]
}
EOF
```
```
"CN"：Common Name，kube-apiserver 从证书中提取该字段作为请求的用户名 (User Name)；浏览器使用该字段验证网站是否合法；
"O"：Organization，kube-apiserver 从证书中提取该字段作为请求用户所属的组 (Group)；
==生成 CA 证书和私钥==：
```
```shell
cat > etcd-csr.json <<EOF
{
  "CN": "etcd",
  "hosts": [
    "127.0.0.1",
    "192.168.0.8",
    "192.168.0.9",
    "192.168.0.10"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "BeiJing",
      "L": "BeiJing",
      "O": "k8s",
      "OU": "System"
    }
  ]
}
EOF
```
```
hosts 字段指定授权使用该证书的 etcd 节点 IP；
```
```shell
cfssl gencert -initca ca-csr.json | cfssljson -bare ca

cfssl gencert -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes etcd-csr.json | cfssljson -bare etcd

mkdir -p /etc/etcd/ssl
cp etcd.pem etcd-key.pem ca.pem /etc/etcd/ssl/
# 其他主机(etcd 和 master) mkdir /etc/etcd后
scp -r /etc/etcd/ssl/ root@192.168.0.8:/etc/etcd/
```

## ETCD部署
```shell
wget https://github.com/etcd-io/etcd/releases/download/v3.3.10/etcd-v3.3.10-linux-amd64.tar.gz
tar -xvf etcd-v3.3.10-linux-amd64.tar.gz
mv etcd-v3.3.10-linux-amd64/etcd* /usr/local/bin/
mkdir -p /var/lib/etcd
```

```shell
cat > etcd.service <<EOF
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
ExecStart=/usr/local/bin/etcd \\
  --name=${NODE_NAME} \\
  --cert-file=/etc/etcd/ssl/etcd.pem \\
  --key-file=/etc/etcd/ssl/etcd-key.pem \\
  --peer-cert-file=/etc/etcd/ssl/etcd.pem \\
  --peer-key-file=/etc/etcd/ssl/etcd-key.pem \\
  --trusted-ca-file=/etc/etcd/ssl/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ssl/ca.pem \\
  --initial-advertise-peer-urls=https://${NODE_IP}:2380 \\
  --listen-peer-urls=https://${NODE_IP}:2380 \\
  --listen-client-urls=https://${NODE_IP}:2379,http://127.0.0.1:2379 \\
  --advertise-client-urls=https://${NODE_IP}:2379 \\
  --initial-cluster-token=etcd-cluster-0 \\
  --initial-cluster=${ETCD_NODES} \\
  --initial-cluster-state=new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

```shell
mv etcd.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable etcd
systemctl start etcd
```

```shell
# 检测etcd状态
etcdctl \
  --endpoints=https://${NODE_IP}:2379  \
  --ca-file=/etc/etcd/ssl/ca.pem \
  --cert-file=/etc/etcd/ssl/etcd.pem \
  --key-file=/etc/etcd/ssl/etcd-key.pem \
  cluster-health
```

## K8S 节点初始化
```shell
# 配置kubeadmin yum源
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

# 初始化
yum install docker kubelet-1.11.1 kubeadm-1.11.1 kubectl-1.11.1 -y
systemctl enable docker && systemctl start docker
systemctl enable kubelet && systemctl start kubelet
```


## Master镜像获取并初始化集群
```shell
# dockerHub拉取镜像
images=(kube-proxy-amd64:v1.11.1 kube-scheduler-amd64:v1.11.1 kube-controller-manager-amd64:v1.11.1 kube-apiserver-amd64:v1.11.1 etcd-amd64:3.2.18 pause:3.1)
for imageName in ${images[@]} ; do
  docker pull mirrorgooglecontainers/$imageName
  docker tag mirrorgooglecontainers/$imageName k8s.gcr.io/$imageName
  docker rmi mirrorgooglecontainers/$imageName
done
docker pull coredns/coredns:1.1.3
docker tag coredns/coredns:1.1.3 k8s.gcr.io/coredns:1.1.3
docker rmi docker.io/coredns/coredns:1.1.3
```

```shell
cat <<EOF > config.yaml
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
etcd:
  endpoints:
  - https://192.168.0.8:2379
  - https://192.168.0.9:2379
  - https://192.168.0.10:2379
  caFile: /etc/etcd/ssl/ca.pem
  certFile: /etc/etcd/ssl/etcd.pem
  keyFile: /etc/etcd/ssl/etcd-key.pem
  dataDir: /var/lib/etcd
networking:
  podSubnet: 10.244.0.0/16
kubernetesVersion: 1.11.1
api:
  advertiseAddress: ${NODE_IP}
token: "b99a00.a144ef80536d4344"
tokenTTL: "0s"
apiServerCertSANs:
- k8s-master1
- k8s-master2
- k8s-master3
- 192.168.0.11
- 192.168.0.12
- 192.168.0.13
- 192.168.0.14
featureGates:
  CoreDNS: true
EOF
```

```shell
# kubeadm init --kubernetes-version=v1.11.1 --pod-network-cidr=10.244.0.0/16 --service-cidr=10.96.0.0/12 --ignore-preflight-errors=Swap

kubeadm init --config config.yaml

export KUBECONFIG=/etc/kubernetes/admin.conf

# 其他节点(master)操作并转移证书
mkdir -p /etc/kubernetes/
scp -r /etc/kubernetes/pki root@192.168.0.12:/etc/kubernetes

# 安装flannel
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
```

## 测试
```shell
kubectl get cs
kubectl get po --all-namespaces
# 获取token(work节点加入认证)
kubeadm token list
```

## Worker镜像拉取并初始化集群
```shell
# dockerHub拉取镜像
images=(kube-proxy-amd64:v1.11.1 pause:3.1)
for imageName in ${images[@]} ; do
  docker pull mirrorgooglecontainers/$imageName
  docker tag mirrorgooglecontainers/$imageName k8s.gcr.io/$imageName
  docker rmi mirrorgooglecontainers/$imageName
done
# 主节点获取
kubeadm join --token b99a00.a144ef80536d4344 192.168.0.10:6443 --discovery-token-unsafe-skip-ca-verification
```

## 测试
```shell
# 创建deployment
kubectl run kubernetes-bootcamp --image=jocatalin/kubernetes-bootcamp:v1 --port=8080
# 查看deployments状态
kubectl get deploy
# 查看pods状态
kubectl get pods
```