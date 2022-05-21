# 关闭swap
swapoff -a && sysctl -w vm.swappiness=0
sed -i 's/.*swap.*/# &/' /etc/fstab
# 将 SELinux 设置为 permissive 模式（相当于将其禁用）
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
# 关闭防火墙
systemctl disable --now firewalld
# 安装部分依赖
yum install tc socat conntrack-tools -y

## 6443	Kubernetes API 服务器
#firewall-cmd --zone=public --add-port=6443/tcp --permanent
## etcd 服务器客户端 API
#firewall-cmd --zone=public --add-port=2379-2380/tcp --permanent
## 10250	Kubelet API;10251	kube-scheduler;10252	kube-controller-manager
#firewall-cmd --zone=public --add-port=10250-10252/tcp --permanent
