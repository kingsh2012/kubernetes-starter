# 一、预先准备环境
## 1. 准备服务器
准备3台按配置计费的CentOS7云主机,信息如下:(使用内网ip)

| 节点角色 | 外网IP | 内网IP | Hostname |
| ------------ | ------------ | ------------ | ------------ |
| Mater   | 116.196.81.166 | 192.168.0.32 | k8s_master |
| Worker1 | 116.196.86.59 | 192.168.0.33 | k8s_worker1 |
| Worker2 | 116.196.87.66 | 192.168.0.34 | k8s_worker2 |

## 2.Docker安装
```shell
# 安装docker
yum install docker -y
# 接收所有ip的数据包转发
vim /lib/systemd/system/docker.service
#找到ExecStart=xxx，在这行上面加入一行，内容如下：(k8s的网络需要)
ExecStartPost=/sbin/iptables -I FORWARD -s 0.0.0.0/0 -j ACCEPT

# 重启服务
systemctl restart docker
```
## 3.系统设置
```shell
# 关闭防火墙
# 设置系统运行路由转发
cat <<EOF > /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

# 生效配置
sysctl -p /etc/sysctl.d/k8s.conf

# 配置host文件
cat <<EOF >>/etc/hosts
192.168.0.32 k8s_master
192.168.0.33 k8s_worker1
192.168.0.34 k8s_worker2
EOF
```
## 4.下载k8s二进制文件
> [Kubernetes1.9][0]
```shell 
scp root@192.168.0.32:/root/kubernetes-bins.tar.gz .
tar -zxvf kubernetes-bins.tar.gz
mv kubernetes-bins bin
```
## 5.准备配置文件
> 下载[kubernetes-starter文件][1] 并上传所有节点

```shell
git clone https://github.com/msun1996/kubernetes-starter.git
#cd到git代码目录
cd ~/kubernetes-starter
#编辑属性配置（根据文件注释中的说明填写好每个key-value）
vim config.properties
#生成配置文件，确保执行过程没有异常信息
./gen-config.sh simple
#查看生成的配置文件，确保脚本执行成功
find target/ -type f
```
### 配置文件说明

*   **gen-config.sh**
> shell脚本，用来根据每个同学自己的集群环境(ip，hostname等)，根据下面的模板，生成适合大家各自环境的配置文件。生成的文件会放到target文件夹下。

*   **kubernetes-simple**
> 简易版kubernetes配置模板（剥离了认证授权）。

*   **kubernetes-with-ca**
> 在simple基础上增加认证授权部分。

*   **service-config**
> 实践用的，通过这些配置，把我们的微服务都运行到kubernetes集群中。

  [0]:https://pan.baidu.com/s/1i8ZAjIz4d8W_OYABz-7boQ
  [1]:https://github.com/msun1996/kubernetes-starter