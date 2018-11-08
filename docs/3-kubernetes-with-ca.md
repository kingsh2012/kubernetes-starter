# 三 带安全认证的完整集群部署
## 1.环境准备
### 1.0停止所有服务(如果部署基础服务)
```shell
# 主节点删除所有services、deployments、pods
#停掉worker节点的服务
service kubelet stop && rm -fr /var/lib/kubelet/*
service kube-proxy stop && rm -fr /var/lib/kube-proxy/*
service kube-calico stop

#停掉master节点的服务
service kube-calico stop
service kube-scheduler stop
service kube-controller-manager stop
service kube-apiserver stop
service etcd stop && rm -fr /var/lib/etcd/*
```
### 1.1生成所需服务配置文件（所有节点）
```shell
cd ~/kubernetes-starter
# 修改部分配置（https）
vim config.properties
#生成配置
./gen-config.sh with-ca
```
### 1.2安装cfssl(所有节点)
```shell
wget -q https://pkg.cfssl.org/R1.2/cfssl_linux-amd64 https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
#修改为可执行权限
chmod +x cfssl_linux-amd64 cfssljson_linux-amd64
#移动到bin目录
mv cfssl_linux-amd64 /usr/local/bin/cfssl
mv cfssljson_linux-amd64 /usr/local/bin/cfssljson
#验证
cfssl version
```
### 1.3安装根证书(主节点)
```shell
#所有证书相关的东西都放在这
mkdir -p /etc/kubernetes/ca
#准备生成证书的配置文件
cp ~/kubernetes-starter/target/ca/ca-config.json /etc/kubernetes/ca
cp ~/kubernetes-starter/target/ca/ca-csr.json /etc/kubernetes/ca
#生成证书和秘钥
cd /etc/kubernetes/ca
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
#生成完成后会有以下文件（我们最终想要的就是ca-key.pem和ca.pem，一个秘钥，一个证书）
ls
```
## 2.Etcd部署(Master)
### 2.1 准备证书
```shell
#etcd证书放在这
mkdir -p /etc/kubernetes/ca/etcd
#准备etcd证书配置
cp ~/kubernetes-starter/target/ca/etcd/etcd-csr.json /etc/kubernetes/ca/etcd/
cd /etc/kubernetes/ca/etcd/
#使用根证书(ca.pem)签发etcd证书
cfssl gencert \
-ca=/etc/kubernetes/ca/ca.pem \
-ca-key=/etc/kubernetes/ca/ca-key.pem \
-config=/etc/kubernetes/ca/ca-config.json \
-profile=kubernetes etcd-csr.json | cfssljson -bare etcd
#跟之前类似生成三个文件etcd.csr是个中间证书请求文件，我们最终要的是etcd-key.pem和etcd.pem
ls
```
### 2.2启动服务
```shell
cp ~/kubernetes-starter/target/master-node/etcd.service /lib/systemd/system/
systemctl daemon-reload
systemctl enable etcd.service
# 创建工作目录用于数据保存
mkdir -p /var/lib/etcd
systemctl start etcd.service
#验证etcd服务（endpoints自行替换）
ETCDCTL_API=3 etcdctl \
--endpoints=https://192.168.0.32:2379  \
--cacert=/etc/kubernetes/ca/ca.pem \
--cert=/etc/kubernetes/ca/etcd/etcd.pem \
--key=/etc/kubernetes/ca/etcd/etcd-key.pem \
endpoint health
```
## 3.Api-server部署(Master)
### 3.1准备安全证书
```shell
#api-server证书放在这，api-server是核心，文件夹叫kubernetes吧，如果想叫apiserver也可以，不过相关的地方都需要修改哦
mkdir -p /etc/kubernetes/ca/kubernetes
#准备apiserver证书配置
cp ~/kubernetes-starter/target/ca/kubernetes/kubernetes-csr.json /etc/kubernetes/ca/kubernetes/
cd /etc/kubernetes/ca/kubernetes/
#使用根证书(ca.pem)签发kubernetes证书
cfssl gencert \
-ca=/etc/kubernetes/ca/ca.pem \
-ca-key=/etc/kubernetes/ca/ca-key.pem \
-config=/etc/kubernetes/ca/ca-config.json \
-profile=kubernetes kubernetes-csr.json | cfssljson -bare kubernetes
#跟之前类似生成三个文件kubernetes.csr是个中间证书请求文件，我们最终要的是kubernetes-key.pem和kubernetes.pem
ls
```
```shell
#生成随机token
head -c 16 /dev/urandom | od -An -t x | tr -d ' '
8afdf3c4eb7c74018452423c29433609
#按照固定格式写入token.csv，注意替换token内容
echo "8afdf3c4eb7c74018452423c29433609,kubelet-bootstrap,10001,\"system:kubelet-bootstrap\"" > /etc/kubernetes/ca/kubernetes/token.csv
```
### 3.2启动服务
```shell
cp ~/kubernetes-starter/target/master-node/kube-apiserver.service /lib/systemd/system/
systemctl daemon-reload
systemctl enable kube-apiserver.service
systemctl start kube-apiserver

#检查日志
journalctl -f -u kube-apiserver
```
## 4.Controller-manager（Master）(apiserver同服务器不需证书)
```shell
cp ~/kubernetes-starter/target/master-node/kube-controller-manager.service /lib/systemd/system/
systemctl daemon-reload
systemctl enable kube-controller-manager
systemctl start kube-controller-manager
#检查日志
journalctl -f -u kube-controller-manager
```
## 5.Scheduler部署(Master)(apiserver同服务器不需证书)
```shell
cp ~/kubernetes-starter/target/master-node/kube-scheduler.service /lib/systemd/system/
systemctl enable kube-scheduler.service
systemctl start kube-scheduler.service
journalctl -f -u kube-scheduler.service
```
## 6.Calico部署(所有节点)
### 6.1准备安全证书
* calico/node 这个docker 容器运行时访问 etcd 使用证书
* cni 配置文件中，cni 插件需要访问 etcd 使用证书
* calicoctl 操作集群网络时访问 etcd 使用证书
* calico/kube-controllers 同步集群网络策略时访问 etcd 使用证书
```shell
#calico证书放在这
mkdir -p /etc/kubernetes/ca/calico
#准备calico证书配置 - calico只需客户端证书，因此证书请求中 hosts 字段可以为空
cp ~/kubernetes-starter/target/ca/calico/calico-csr.json /etc/kubernetes/ca/calico/
cd /etc/kubernetes/ca/calico/
#使用根证书(ca.pem)签发calico证书
cfssl gencert \
-ca=/etc/kubernetes/ca/ca.pem \
-ca-key=/etc/kubernetes/ca/ca-key.pem \
-config=/etc/kubernetes/ca/ca-config.json \
-profile=kubernetes calico-csr.json | cfssljson -bare calico
#我们最终要的是calico-key.pem和calico.pem
ls
```
### 6.2启动服务
```shell
cp ~/kubernetes-starter/target/all-node/kube-calico.service /lib/systemd/system/
systemctl enable kube-calico.service
systemctl start kube-calico.service
journalctl -f -u kube-calico.service
# 验证查看
calicoctl node status
```
## 7.Kubectl部署（任意节点）
### 7.1准备证书
```shell
#kubectl证书放在这，由于kubectl相当于系统管理员，我们使用admin命名
mkdir -p /etc/kubernetes/ca/admin
#准备admin证书配置 - kubectl只需客户端证书，因此证书请求中 hosts 字段可以为空
cp ~/kubernetes-starter/target/ca/admin/admin-csr.json /etc/kubernetes/ca/admin/
cd /etc/kubernetes/ca/admin/
#使用根证书(ca.pem)签发admin证书
cfssl gencert \
-ca=/etc/kubernetes/ca/ca.pem \
-ca-key=/etc/kubernetes/ca/ca-key.pem \
-config=/etc/kubernetes/ca/ca-config.json \
-profile=kubernetes admin-csr.json | cfssljson -bare admin
#我们最终要的是admin-key.pem和admin.pem
ls
```
### 7.2配置
```shell
#指定apiserver的地址和证书位置（ip自行修改）
kubectl config set-cluster kubernetes \
--certificate-authority=/etc/kubernetes/ca/ca.pem \
--embed-certs=true \
--server=https://192.168.0.32:6443
#设置客户端认证参数，指定admin证书和秘钥
kubectl config set-credentials admin \
--client-certificate=/etc/kubernetes/ca/admin/admin.pem \
--embed-certs=true \
--client-key=/etc/kubernetes/ca/admin/admin-key.pem
#关联用户和集群
kubectl config set-context kubernetes \
--cluster=kubernetes --user=admin
#设置当前上下文
kubectl config use-context kubernetes

#设置结果就是一个配置文件，可以看看内容
cat ~/.kube/config

#验证查看
kubectl get componentstatus
```
## 8.Kubelet部署
> 我们这里让kubelet使用引导token的方式认证，所以认证方式跟之前的组件不同，它的证书不是手动生成，而是由工作节点TLS BootStrap 向api-server请求，由主节点的controller-manager 自动签发。

### 8.1 创建角色绑定（Master）
> 引导token的方式要求客户端向api-server发起请求时告诉他你的用户名和token，并且这个用户是具有一个特定的角色：system:node-bootstrapper，所以需要先将 bootstrap token 文件中的 kubelet-bootstrap 用户赋予这个特定角色，然后 kubelet 才有权限发起创建认证请求。

```shell
#可以通过下面命令查询clusterrole列表
kubectl -n kube-system get clusterrole

#可以回顾一下token文件的内容
cat /etc/kubernetes/ca/kubernetes/token.csv

#创建角色绑定（将用户kubelet-bootstrap与角色system:node-bootstrapper绑定）
kubectl create clusterrolebinding kubelet-bootstrap \
--clusterrole=system:node-bootstrapper --user=kubelet-bootstrap
```
### 8.2创建bootstrap.kubeconfig(Worker)
```shell
#设置集群参数(注意替换ip)
kubectl config set-cluster kubernetes \
--certificate-authority=/etc/kubernetes/ca/ca.pem \
--embed-certs=true \
--server=https://192.168.0.32:6443 \
--kubeconfig=bootstrap.kubeconfig
#设置客户端认证参数(注意替换token)
kubectl config set-credentials kubelet-bootstrap \
--token=8afdf3c4eb7c74018452423c29433609 \
--kubeconfig=bootstrap.kubeconfig
#设置上下文
kubectl config set-context default \
--cluster=kubernetes \
--user=kubelet-bootstrap \
--kubeconfig=bootstrap.kubeconfig
#选择上下文
kubectl config use-context default --kubeconfig=bootstrap.kubeconfig
#将刚生成的文件移动到合适的位置
mv bootstrap.kubeconfig /etc/kubernetes/
```
### 8.3启动kubele服务
```shell
#确保相关目录存在
mkdir -p /var/lib/kubelet
mkdir -p /etc/kubernetes
mkdir -p /etc/cni/net.d

#复制kubelet服务配置文件
cp ~/kubernetes-starter/target/worker-node/kubelet.service /lib/systemd/system/
#复制kubelet用到的cni插件配置文件
cp ~/kubernetes-starter/target/worker-node/10-calico.conf /etc/cni/net.d/

systemctl enable kubelet.service
service kubelet start
journalctl -f -u kubelet
```
## 9.Kube-proxy部署
### 9.1准备证书
```shell
#proxy证书放在这
mkdir -p /etc/kubernetes/ca/kube-proxy

#准备proxy证书配置 - proxy只需客户端证书，因此证书请求中 hosts 字段可以为空。
#CN 指定该证书的 User 为 system:kube-proxy，预定义的 ClusterRoleBinding system:node-proxy 将User system:kube-proxy 与 Role system:node-proxier 绑定，授予了调用 kube-api-server proxy的相关 API 的权限
cp ~/kubernetes-starter/target/ca/kube-proxy/kube-proxy-csr.json /etc/kubernetes/ca/kube-proxy/
cd /etc/kubernetes/ca/kube-proxy/

#使用根证书(ca.pem)签发calico证书
cfssl gencert \
-ca=/etc/kubernetes/ca/ca.pem \
-ca-key=/etc/kubernetes/ca/ca-key.pem \
-config=/etc/kubernetes/ca/ca-config.json \
-profile=kubernetes kube-proxy-csr.json | cfssljson -bare kube-proxy
#我们最终要的是kube-proxy-key.pem和kube-proxy.pem
ls
```
### 9.2生成kube-proxy.kubeconfig配置文件
```shell
#设置集群参数（注意替换ip）
kubectl config set-cluster kubernetes \
--certificate-authority=/etc/kubernetes/ca/ca.pem \
--embed-certs=true \
--server=https://192.168.0.32:6443 \
--kubeconfig=kube-proxy.kubeconfig
#置客户端认证参数
kubectl config set-credentials kube-proxy \
--client-certificate=/etc/kubernetes/ca/kube-proxy/kube-proxy.pem \
--client-key=/etc/kubernetes/ca/kube-proxy/kube-proxy-key.pem \
--embed-certs=true \
--kubeconfig=kube-proxy.kubeconfig
#设置上下文参数
kubectl config set-context default \
--cluster=kubernetes \
--user=kube-proxy \
--kubeconfig=kube-proxy.kubeconfig
#选择上下文
kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
#移动到合适位置
mv kube-proxy.kubeconfig /etc/kubernetes/kube-proxy.kubeconfig
```
```shell
#确保工作目录存在
mkdir -p /var/lib/kube-proxy
#复制kube-proxy服务配置文件
cp ~/kubernetes-starter/target/worker-node/kube-proxy.service /lib/systemd/system/

systemctl enable kube-proxy.service
service kube-proxy start
journalctl -f -u kube-proxy
```
## 10.Kube-dns部署
> kube-dns有些特别，因为它本身是运行在kubernetes集群中，以kubernetes应用的形式运行。所以它的认证授权方式跟之前的组件都不一样。它需要用到service account认证和RBAC授权。
**service account认证：**
每个service account都会自动生成自己的secret，用于包含一个ca，token和secret，用于跟api-server认证
**RBAC授权：**
权限、角色和角色绑定都是kubernetes自动创建好的。我们只需要创建一个叫做kube-dns的 ServiceAccount即可，官方现有的配置已经把它包含进去了。

```shell
$ kubectl create -f ~/kubernetes-starter/target/services/kube-dns.yaml
# 启动是否成功
$ kubectl -n kube-system get pods
```
