# 二、基础集群部署
## 1.ETCD部署(Master)
```shell
# 服务配置文件copy
cp ~/kubernetes-starter/target/master-node/etcd.service /lib/systemd/system/
systemctl enable etcd.service
# 创建工作目录用于数据保存
mkdir -p /var/lib/etcd
systemctl start etcd.service
# 查看服务日志，看是否有错误信息，确保服务正常
journalctl -f -u etcd.service
```
## 2.APIServer部署(Master)
> 生产环境为了保证apiserver的高可用一般会部署2+个节点，在上层做一个lb做负载均衡，比如haproxy。

```shell
cp ~/kubernetes-starter/target/master-node/kube-apiserver.service /lib/systemd/system/
systemctl enable kube-apiserver.service
systemctl start kube-apiserver.service
journalctl -f -u kube-apiserver
```
* **kube-apiserver.service**配置文件说明

```
[Unit]
Description=Kubernetes API Server
...
[Service]
#可执行文件的位置
ExecStart=/home/michael/bin/kube-apiserver \
#非安全端口(8080)绑定的监听地址 这里表示监听所有地址
--insecure-bind-address=0.0.0.0 \
#不使用https
--kubelet-https=false \
#kubernetes集群的虚拟ip的地址范围
--service-cluster-ip-range=10.68.0.0/16 \
#service的nodeport的端口范围限制
--service-node-port-range=20000-40000 \
#很多地方都需要和etcd打交道，也是唯一可以直接操作etcd的模块
--etcd-servers=http://192.168.1.102:2379 \
···
```

## 3.Controller Manager部署(Master)
> controller-manager、scheduler和apiserver 三者的功能紧密相关，一般运行在同一个机器上，我们可以把它们当做一个整体来看，所以保证了apiserver的高可用即是保证了三个模块的高可用。也可以同时启动多个controller-manager进程，但只有一个会被选举为leader提供服务。

```shell
cp ~/kubernetes-starter/target/master-node/kube-controller-manager.service /lib/systemd/system/
systemctl enable kube-controller-manager.service
systemctl start kube-controller-manager.service
journalctl -f -u kube-controller-manager.service
```
* **kube-controller-manager.service**配置文件说明

```shell
[Unit]
Description=Kubernetes Controller Manager
...
[Service]
ExecStart=/home/michael/bin/kube-controller-manager \
#对外服务的监听地址，这里表示只有本机的程序可以访问它
--address=127.0.0.1 \
#apiserver的url
--master=http://127.0.0.1:8080 \
#服务虚拟ip范围，同apiserver的配置
--service-cluster-ip-range=10.68.0.0/16 \
#pod的ip地址范围
--cluster-cidr=172.20.0.0/16 \
#下面两个表示不使用证书，用空值覆盖默认值
--cluster-signing-cert-file= \
--cluster-signing-key-file= \
...
```
## 4.Scheduler部署(Master)
```shell
cp ~/kubernetes-starter/target/master-node/kube-scheduler.service /lib/systemd/system/
systemctl enable kube-scheduler.service
systemctl start kube-scheduler.service
journalctl -f -u kube-scheduler.service
```
* **kube-scheduler.service**配置文件说明

```shell
[Unit]
Description=Kubernetes Scheduler
...
[Service]
ExecStart=/home/michael/bin/kube-scheduler \
#对外服务的监听地址，这里表示只有本机的程序可以访问它
--address=127.0.0.1 \
#apiserver的url
--master=http://127.0.0.1:8080 \
...
```
## 5.Calico部署(所有节点)
> Calico实现了CNI接口，是kubernetes网络方案的一种选择，它一个纯三层的数据中心网络方案（不需要Overlay），并且与OpenStack、Kubernetes、AWS、GCE等IaaS和容器平台都有良好的集成。 Calico在每一个计算节点利用Linux Kernel实现了一个高效的vRouter来负责数据转发，而每个vRouter通过BGP协议负责把自己上运行的workload的路由信息像整个Calico网络内传播——小规模部署可以直接互联，大规模下可通过指定的BGP route reflector来完成。 这样保证最终所有的workload之间的数据流量都是通过IP路由的方式完成互联的。

```shell
cp ~/kubernetes-starter/target/all-node/kube-calico.service /lib/systemd/system/
systemctl enable kube-calico.service
systemctl start kube-calico.service
journalctl -f -u kube-calico.service
```
```shell
# 查看docker运行
docker ps
# 查看节点运行
calicoctl node status
# 查看集群ippool情况（Master）
calicoctl get ipPool -o yaml
```
* **kube-calico.service**配置文件说明

```shell
[Unit]
Description=calico node
...
[Service]
#以docker方式运行
ExecStart=/usr/bin/docker run --net=host --privileged --name=calico-node \
#指定etcd endpoints（这里主要负责网络元数据一致性，确保Calico网络状态的准确性）
-e ETCD_ENDPOINTS=http://192.168.1.102:2379 \
#网络地址范围（同上面ControllerManager）
-e CALICO_IPV4POOL_CIDR=172.20.0.0/16 \
#镜像名，为了加快大家的下载速度，镜像都放到了阿里云上
registry.cn-hangzhou.aliyuncs.com/imooc/calico-node:v2.6.2
```
## 6.配置Kubectl命令（任意节点）
> kubectl是Kubernetes的命令行工具，是Kubernetes用户和管理员必备的管理工具。 kubectl提供了大量的子命令，方便管理Kubernetes集群中的各种功能。
```shell
#指定apiserver地址（ip替换为你自己的api-server地址）
kubectl config set-cluster kubernetes  --server=http://192.168.0.32:8080
#指定设置上下文，指定cluster
kubectl config set-context kubernetes --cluster=kubernetes
#选择默认的上下文
kubectl config use-context kubernetes
```
## 7.kubelet部署（Worker）
```shell
#确保相关目录存在
mkdir -p /var/lib/kubelet
mkdir -p /etc/kubernetes
mkdir -p /etc/cni/net.d

#复制kubelet服务配置文件
cp ~/kubernetes-starter/target/worker-node/kubelet.service /lib/systemd/system/
#复制kubelet依赖的配置文件
cp ~/kubernetes-starter/target/worker-node/kubelet.kubeconfig /etc/kubernetes/
#复制kubelet用到的cni插件配置文件
cp ~/kubernetes-starter/target/worker-node/10-calico.conf /etc/cni/net.d/

systemctl enable kubelet.service
systemctl start kubelet.service
journalctl -f -u kubelet.service
```
* **kubelet.service** 配置文件说明

```shell
[Unit]
Description=Kubernetes Kubelet
[Service]
#kubelet工作目录，存储当前节点容器，pod等信息
WorkingDirectory=/var/lib/kubelet
ExecStart=/home/michael/bin/kubelet \
#对外服务的监听地址
--address=192.168.0.32 \
#指定基础容器的镜像，负责创建Pod 内部共享的网络、文件系统等，这个基础容器非常重要：K8S每一个运行的 POD里面必然包含这个基础容器，如果它没有运行起来那么你的POD 肯定创建不了
--pod-infra-container-image=registry.cn-hangzhou.aliyuncs.com/imooc/pause-amd64:3.0 \
#访问集群方式的配置，如api-server地址等
--kubeconfig=/etc/kubernetes/kubelet.kubeconfig \
#声明cni网络插件
--network-plugin=cni \
#cni网络配置目录，kubelet会读取该目录下得网络配置
--cni-conf-dir=/etc/cni/net.d \
#指定 kubedns 的 Service IP(可以先分配，后续创建 kubedns 服务时指定该 IP)，--cluster-domain 指定域名后缀，这两个参数同时指定后才会生效
--cluster-dns=10.68.0.2 \
...
```
* **kubelet.kubeconfig**配置文件说明

```shell
apiVersion: v1
clusters:
- cluster:
#跳过tls，即是kubernetes的认证
insecure-skip-tls-verify: true
#api-server地址
server: http://192.168.0.33:8080
...
```
* **10-Calico.conf**calico作为kubernets的CNI插件的配置

```json
{  
  "name": "calico-k8s-network",  
  "cniVersion": "0.1.0",  
  "type": "calico",  
    <!--etcd的url-->
    "ed_endpoints": "http://192.168.0.33:2379",  
    "logevel": "info",  
    "ipam": {  
        "type": "calico-ipam"  
   },  
    "kubernetes": {  
        <!--api-server的url-->
        "k8s_api_root": "http://192.168.0.33:8080"  
    }  
}  
```
## 8.测试
```shell
# 创建deployment
kubectl run kubernetes-bootcamp --image=jocatalin/kubernetes-bootcamp:v1 --port=8080
# 查看deployments状态
kubectl get deploy
# 查看pods状态
kubectl get pods

# 启动测试
kubectl proxy
# 另起bash访问测试
curl http://localhost:8001/api/v1/proxy/namespaces/default/pods/kubernetes-bootcamp-6b7849c495-d5f6g/

# 复制pod
kubectl scale deploy kubernetes-bootcamp --replicas=5
# gen更新deployment版本
kubectl set image deploy kubernetes-bootcamp kubernetes-bootcamp=jocatalin/kubernetes-bootcamp:v2
# 查看更新状态
kubectl rollout status deploy kubernetes-bootcamp
```
## 9.Kube-proxy部署(Worker)
```shell
#确保工作目录存在
mkdir -p /var/lib/kube-proxy
#复制kube-proxy服务配置文件
cp ~/kubernetes-starter/target/worker-node/kube-proxy.service /lib/systemd/system/
#复制kube-proxy依赖的配置文件
cp ~/kubernetes-starter/target/worker-node/kube-proxy.kubeconfig /etc/kubernetes/

systemctl enable kube-proxy.service
systemctl start kube-proxy
journalctl -f -u kube-proxy
```

```shell
# kube-proxy产生Service
kubectl expose deploy kubernetes-bootcamp --type="NodePort" --target-port=8080 --port=80
# 查看service (默认会产生Apiservice负载均衡的service)
kubectl get service
# 验证（21990即查看kube-proxy的对外暴露端口）
# 访问容器端口（在master节点）
curl 192.168.0.33:21990
# 访问服务端口（进入任意docker,访问产生的service ip）
curl 10.68.56.211
```

**kube-proxy.service**配置文件说明
```shell
[Unit]
Description=Kubernetes Kube-Proxy Server ...
[Service]
#工作目录
WorkingDirectory=/var/lib/kube-proxy
ExecStart=/home/michael/bin/kube-proxy \
#监听地址
--bind-address=192.168.0.32 \
#依赖的配置文件，描述了kube-proxy如何访问api-server
--kubeconfig=/etc/kubernetes/kube-proxy.kubeconfig \
...
```
## 10.Kube-dns部署(Master)
```shell
# 执行部署
kubectl create -f ~/kubernetes-starter/target/services/kube-dns.yaml
# 查看服务
kubectl -n kube-system get svc
# 进任意容器，测试访问（nginx-service是以启动的nginx service的命名）
curl nginx-service:8080