#!/usr/bin/env bash

#############################
# kubernetes集群自动化部署主脚本(运行在任意节点，此节点要求有外网，此节点务必不要提前yum 安装docker,负责会导致下载rpm包缺少依赖)
# 负责各节点资源分发
# bootstrap.sh
############### 资源目录 ##############
cd
mkdir -p nodes
############### 使用前需填写信息 ######################
# 集群信息填写
# etcd 以etcd开头(hostname要与主机保持一致)
# master 以k8s-master开头
# worker 以k8s-worker开头
# vip 指虚拟IP
cat > nodes/info << EOF
192.168.0.14 vip
192.168.0.10 etcd1
192.168.0.8 etcd2
192.168.0.9 etcd3
192.168.0.11 k8s-master1
192.168.0.12 k8s-master2
192.168.0.13 k8s-master3
192.168.0.17 k8s-worker
EOF

# 各节点统一的密码,work节点加入token
export password="K8s960304"
export token="b99a00.a144ef80536d4344"

echo $token >nodes/token
################### 资源准备 #########################

#### etcd资源 ####
# etcd节点所需资源
wget https://github.com/etcd-io/etcd/releases/download/v3.3.10/etcd-v3.3.10-linux-amd64.tar.gz
echo no | mv etcd-v3.3.10-linux-amd64.tar.gz nodes/

#### yum 包资源 ####
# K8s所需yum包
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

yum install yum-plugin-downloadonly -y
yum -y install --downloadonly --downloaddir=nodes docker kubelet-1.11.1 kubeadm-1.11.1 kubectl-1.11.1
yum install docker -y
systemctl enable docker && systemctl start docker

#### 镜像资源 ####
# dockerHub拉取镜像,重tag
images=(kube-proxy-amd64:v1.11.1 kube-scheduler-amd64:v1.11.1 kube-controller-manager-amd64:v1.11.1 kube-apiserver-amd64:v1.11.1 etcd-amd64:3.2.18 pause:3.1)
for imageName in ${images[@]} ; do
  docker pull mirrorgooglecontainers/$imageName
  docker tag mirrorgooglecontainers/$imageName k8s.gcr.io/$imageName
  docker rmi mirrorgooglecontainers/$imageName
  docker save -o nodes/$imageName.tar k8s.gcr.io/$imageName
done
docker pull coredns/coredns:1.1.3
docker tag coredns/coredns:1.1.3 k8s.gcr.io/coredns:1.1.3
docker rmi docker.io/coredns/coredns:1.1.3
docker save -o nodes/coredns:1.1.3.tar k8s.gcr.io/coredns:1.1.3

# flannel 镜像
wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
imageName=`cat kube-flannel.yml | grep image | awk '{print $2}'| uniq | grep amd64 |xargs`
docker pull $imageName
docker save -o nodes/flannel.tar $imageName
echo no | mv kube-flannel.yml nodes/

#### master config.yml配置文件 ####
export VIP=`cat nodes/info | grep vip | awk '{print $1}'`
export endpoints=`cat nodes/info | grep etcd | awk '{print "  - https://"$1":2379"}'`
export apiServerCertSANs=`cat nodes/info | grep k8s-master | awk '{print "- "$1"\n""- "$2}'`
cat <<EOF > nodes/config.yaml
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
etcd:
  endpoints:
$endpoints
  caFile: /etc/etcd/ssl/ca.pem
  certFile: /etc/etcd/ssl/etcd.pem
  keyFile: /etc/etcd/ssl/etcd-key.pem
  dataDir: /var/lib/etcd
networking:
  podSubnet: 10.244.0.0/16
kubernetesVersion: 1.11.1
api:
  advertiseAddress: \$NODE_IP
token: "$token"
tokenTTL: "0s"
apiServerCertSANs:
$apiServerCertSANs
- $VIP
featureGates:
  CoreDNS: true
EOF

################## ca证书 #############################

wget https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
chmod +x cfssl_linux-amd64
echo no | mv cfssl_linux-amd64 /usr/local/bin/cfssl

wget https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
chmod +x cfssljson_linux-amd64
echo no | mv cfssljson_linux-amd64 /usr/local/bin/cfssljson

wget https://pkg.cfssl.org/R1.2/cfssl-certinfo_linux-amd64
chmod +x cfssl-certinfo_linux-amd64
echo no | mv cfssl-certinfo_linux-amd64 /usr/local/bin/cfssl-certinfo

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

export hosts="["`cat nodes/info | awk '{printf "\""$1"\"," }'`"\"127.0.0.1\"""]"

cat > etcd-csr.json <<EOF
{
  "CN": "etcd",
  "hosts": $hosts,
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

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

cfssl gencert -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes etcd-csr.json | cfssljson -bare etcd

echo no | cp etcd.pem etcd-key.pem ca.pem nodes/

######################### 节点运行脚本文件 ###########################

######### etcd节点脚本 ############
cat >nodes/etcd.sh <<BOF
#!/usr/bin/env bash
##### 环境准备 ####
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
cat nodes/info >>/etc/hosts
# 获取主机IP
export NODE_IP=\`ifconfig eth | grep netmask| awk '{print \$2}'\`
# 获取主机域名
export NODE_NAME=\`cat nodes/info | awk '\$1=="'\$NODE_IP'"{print \$2}'\`
# 获取所有ETCD主机
export ETCD_NODES=\`cat nodes/info | grep etcd | awk '{print \$2"=https://"\$1":2380"}'| xargs| sed 's/ /,/g'\`
#### ETCD部署 ####
cd nodes/
# 证书
mkdir -p /etc/etcd/ssl
echo no | cp etcd.pem etcd-key.pem ca.pem /etc/etcd/ssl/
# 解压部署
tar -xvf etcd-v3.3.10-linux-amd64.tar.gz
echo no | mv etcd-v3.3.10-linux-amd64/etcd* /usr/local/bin/
mkdir -p /var/lib/etcd
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
  --name=\${NODE_NAME} \\
  --cert-file=/etc/etcd/ssl/etcd.pem \\
  --key-file=/etc/etcd/ssl/etcd-key.pem \\
  --peer-cert-file=/etc/etcd/ssl/etcd.pem \\
  --peer-key-file=/etc/etcd/ssl/etcd-key.pem \\
  --trusted-ca-file=/etc/etcd/ssl/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ssl/ca.pem \\
  --initial-advertise-peer-urls=https://\${NODE_IP}:2380 \\
  --listen-peer-urls=https://\${NODE_IP}:2380 \\
  --listen-client-urls=https://\${NODE_IP}:2379,http://127.0.0.1:2379 \\
  --advertise-client-urls=https://\${NODE_IP}:2379 \\
  --initial-cluster-token=etcd-cluster-0 \\
  --initial-cluster=\${ETCD_NODES} \\
  --initial-cluster-state=new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
echo no | mv etcd.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable etcd
systemctl start etcd
BOF

######### K8sMaster ########
cat >nodes/master.sh <<BOF
#!/usr/bin/env bash
##### 环境准备 ####
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
cat nodes/info >>/etc/hosts
# 获取主机IP
export NODE_IP=\`ifconfig eth | grep netmask| awk '{print \$2}'\`
# 获取主机域名
export NODE_NAME=\`cat nodes/info | awk '\$1=="'\$NODE_IP'"{print \$2}'\`
mkdir -p /etc/etcd/ssl
#### K8sMaster节点部署 ####
cd nodes/
# 安装包
rpm -ivh *.rpm --nodeps --force
systemctl enable docker && systemctl start docker
systemctl enable kubelet && systemctl start kubelet
# 载入镜像
export images=\`ls | grep .tar$\`
for image in \${images[@]} ; do
    echo \$image
    docker load -i \$image
done
echo no | mv ca.pem etcd.pem etcd-key.pem /etc/etcd/ssl
sed -ie 's/\$NODE_IP/'\$NODE_IP'/g' config.yaml
kubeadm init --config config.yaml
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl apply -f kube-flannel.yml
BOF

######## K8sWorker ########
cat >nodes/worker.sh <<BOF
#!/usr/bin/env bash
##### 环境准备 ####
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
cat nodes/info >>/etc/hosts
# 获取主机IP
export NODE_IP=\`ifconfig eth | grep netmask| awk '{print \$2}'\`
# 获取主机域名
export NODE_NAME=\`cat nodes/info | awk '\$1=="'\$NODE_IP'"{print \$2}'\`
cd nodes/
# 安装包
rpm -ivh *.rpm --nodeps --force
systemctl enable docker && systemctl start docker
systemctl enable kubelet && systemctl start kubelet
# 载入镜像
export images=\`ls | grep .tar$\`
for image in \${images[@]} ; do
    echo \$image
    docker load -i \$image
done
# 查找任意主机
export master=\`cat info | grep master | awk '{print \$1}' | xargs | awk '{print \$1}'\`
export token=\`cat token\`
kubeadm join --token \$token \$master:6443 --discovery-token-unsafe-skip-ca-verification
BOF

################# 所有资源分发 ######################
yum install expect -y
export nodesIp=(`cat nodes/info | grep -v vip | awk '{print $1}'| xargs`)
for nodeIp in ${nodesIp[@]} ; do
cat >> autoscp.sh << EOF
set timeout 3600
spawn scp -r nodes/ root@$nodeIp:/root/
expect {
    "*password:" { send "$password\r" }
    "yes/no" { send "yes\r"; exp_continue }
}
expect eof
EOF
done
expect autoscp.sh

rm -f autoscp.sh

############### ETCD节点部署 ##################
export etcdsIp=(`cat nodes/info | grep etcd | awk '{print $1}'| xargs`)
for nodeIp in ${etcdsIp[@]} ; do
#### 远程登录执行部署脚本 ####
cat >>autossh.sh << EOF
set timeout 3600
spawn ssh root@$nodeIp
expect {
    "*password:" { send "$password\r";}
    "yes/no" { send "yes\r"; exp_continue }
}
expect "~]#"
send "/usr/bin/bash nodes/etcd.sh\r"
expect "~]#"
send "exit\r"
EOF
done

expect autossh.sh

rm -f autossh.sh

############### K8s master部署 ###################
export masterIp=(`cat nodes/info | grep k8s-master | awk '{print $1}'| xargs`)
export i=0
for nodeIp in ${masterIp[@]} ; do

## 第一个产生ca证书的节点让其证书文件回传,其他的主节点推送证书
let i=$i+1
if [[ $i -ne 1 ]]; then
cat > autoscp.sh << EOF
spawn ssh  root@$nodeIp "mkdir /etc/kubernetes/"
expect {
    "*password:" { send "$password\r" }
    "yes/no" { send "yes\r"; exp_continue }
}
expect eof
spawn scp -r /root/nodes/pki/  root@$nodeIp:/etc/kubernetes/
expect {
    "*password:" { send "$password\r" }
    "yes/no" { send "yes\r"; exp_continue }
}
expect eof
EOF
expect autoscp.sh
fi

##### 远程登录执行部署脚本 ####
cat >autossh.sh << EOF
set timeout 3600
spawn ssh root@$nodeIp
expect {
    "*password:" { send "$password\r";}
    "yes/no" { send "yes\r"; exp_continue }
}
expect "~]#"
send "/usr/bin/bash nodes/master.sh\r"
expect "~]#"
send "exit\r"
EOF
expect autossh.sh

if [[ $i -eq 1 ]]; then
cat > autoscp.sh << EOF
spawn scp -r root@$nodeIp:/etc/kubernetes/pki /root/nodes/
expect {
    "*password:" { send "$password\r" }
    "yes/no" { send "yes\r"; exp_continue }
}
expect eof
EOF
expect autoscp.sh
fi

done

rm -f autossh.sh

#################### K8s worker部署 ###################
export workersIp=(`cat nodes/info | grep worker | awk '{print $1}'| xargs`)
for nodeIp in ${workersIp[@]} ; do
#### 远程登录执行部署脚本 ####
cat >>autossh.sh << EOF
set timeout 3600
spawn ssh root@$nodeIp
expect {
    "*password:" { send "$password\r";}
    "yes/no" { send "yes\r"; exp_continue }
}
expect "~]#"
send "/usr/bin/bash nodes/worker.sh\r"
expect "~]#"
send "exit\r"
EOF
done

expect autossh.sh

rm -f autossh.sh