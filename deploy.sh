#/bin/bash

########################################################
# 名称；脚本化部署科学上网服务器                            #
# 工具：shadowsocks-libv, UDPSpeeder V2, UDP2Raw-tunnel #
# 日期：2019年9月22日                                    #
# 作者：York                                            #
########################################################

# 自定义输出文本颜色
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

# 脚本运行变量
DDNS_HOST=xxxxx
DDNS_UPDATE_KEY=yyyyy

SS_CONTAINER_ID=""
SS_PASSWORD=""
SS_METHOD=chacha20-ietf-poly1305
SS_SERVER_ADDR=0.0.0.0
SS_SERVER_PORT=8443
SS_TIMEOUT=300
SS_DNS_ADDRS=8.8.8.8,8.8.4.4
SS_ARGS=""

US_CONTAINER_ID=""
US_LISTEN_IP=0.0.0.0
US_LISTEN_PORT=4096
US_TARGET_IP=127.0.0.1
US_TARGET_PORT=8443
US_FEC=10:6
US_KEY=""
US_TIMEOUT=3

UR_CONTAINER_ID=""
UR_LISTEN_IP=0.0.0.0
UR_LISTEN_PORT=4097
UR_TARGET_IP=127.0.0.1
UR_TARGET_PORT=4096
UR_KEY=""
UR_RAW_MODE=faketcp
UR_ARGS=""

# 检测BBR功能是否开启
check_bbr(){
	check_bbr_status_on=`sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'`
	if [[ "${check_bbr_status_on}" = "bbr" ]]; then
		check_bbr_status_off=`lsmod | grep bbr`
		if [[ "${check_bbr_status_off}" = "" ]]; then
			return 1
		else
			return 0			
		fi
	else
		return 2
	fi
}

# 开启Linux系统的网络BBR功能
enable_bbr(){
	check_bbr
	if [[ $? -eq 0 ]]; then
		echo -e "${Info} BBR 已在运行 !"
	else
		sed -i '/net\.core\.default_qdisc=fq/d' /etc/sysctl.conf
    	sed -i '/net\.ipv4\.tcp_congestion_control=bbr/d' /etc/sysctl.conf

    	echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    	echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    	sysctl -p >> /var/log/bbr.log

		sleep 1s
		
		check_bbr
		case "$?" in
		0)
		echo -e "${Info} BBR 已成功启用 !"
		;;
		1)
		echo -e "${Error} Linux 内核已经启用 BBR，但 BBR 并未运行 ！"
		;;
		2)
		echo -e "${Error} Linux 内核尚未配置启用 BBR ！"
		;;
		*)
		echo "${Error} BBR 状态未知，返回参数: $?}"
		;;
		esac
	fi
}

# 创建或读取/etc/rc.local文件
read_rc_local(){
	if [ -f "/etc/rc.local" ]; then
    	DDNS_HOST=`cat /etc/rc.local | grep 'DDNS_HOST=' | sed -e 's/\(.*\)=\(.*\)/\2/g'`
    	DDNS_UPDATE_KEY=`cat /etc/rc.local | grep 'DDNS_UPDATE_KEY=' | sed -e 's/\(.*\)=\(.*\)/\2/g'`
    else
    	touch /etc/rc.local
		chmod 755 /etc/rc.local
		echo "#/bin/bash -e" >> /etc/rc.local
		echo "" >> /etc/rc.local
		echo "DDNS_HOST=${DDNS_HOST}" >> /etc/rc.local
		echo "DDNS_UPDATE_KEY=${DDNS_UPDATE_KEY}" >> /etc/rc.local
		echo 'updateString="${DDNS_HOST}:${DDNS_UPDATE_KEY}@dyn.dns.he.net/nic/update?hostname=${DDNS_HOST}"' >> /etc/rc.local
		echo 'curl -4 ${updateString}' >> /etc/rc.local
	fi
}

# 修改DDNS主机名
config_ddns_host(){
    echo -e "请输入主机名"
    read -e -p "(当前: ${DDNS_HOST}):" NEW_DDNS_HOST
    if [ ! -z "${NEW_DDNS_HOST}" ]; then
        sed -i "s/${DDNS_HOST}/${NEW_DDNS_HOST}/g" "/etc/rc.local"
        read_rc_local
        [[ "$DDNS_HOST" != "$NEW_DDNS_HOST" ]] && echo -e "${Error} 主机名修改失败 !" && exit 1
        echo -e "${Info} 主机名已修改为 ${DDNS_HOST} !"
    fi
    echo -e "请输入DDNS的更新KEY"
    read -e -p "(当前: ${DDNS_UPDATE_KEY}):" NEW_DDNS_UPDATE_KEY
    if [ ! -z "${NEW_DDNS_UPDATE_KEY}" ]; then
        sed -i "s/${DDNS_UPDATE_KEY}/${NEW_DDNS_UPDATE_KEY}/g" "/etc/rc.local"
        read_rc_local
        [[ "$DDNS_UPDATE_KEY" != "$NEW_DDNS_UPDATE_KEY" ]] && echo -e "${Error} DDNS更新KEY修改失败 !" && exit 1
        echo -e "${Info} DDNS更新KEY已修改为 ${DDNS_UPDATE_KEY} !"
    fi
}

# 检验DDNS修改是否有效
verify_ddns(){
    RESULT=`curl -4 "${DDNS_HOST}:${DDNS_UPDATE_KEY}@dyn.dns.he.net/nic/update?hostname=${DDNS_HOST}"`
    if [[ $RESULT =~ "good" ]]; then
        echo -e "${Info} DDNS配置测试成功 !"
    elif [[ $RESULT =~ "nochg" ]]; then
        echo -e "${Info} DDNS配置测试成功 !"
    else
        echo -e "${Error} DDNS配置测试失败：$RESULT !"
    fi
}

# 读取SS Docker中的运行参数
read_ss_docker(){
	SS_CONTAINER_ID=`docker ps -a |grep 'shadowsocks/shadowsocks-libev' | awk '{print $1}'`
	if [ -z ${SS_CONTAINER_ID} ]; then 
		echo "未找到SS容器！"
	else 
		INSPECT_INFO=`docker inspect ${SS_CONTAINER_ID}`
		SS_PASSWORD=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "PASSWORD=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		SS_METHOD=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "METHOD=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		SS_SERVER_ADDR=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "SERVER_ADDR=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		SS_SERVER_PORT=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "SERVER_PORT=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		SS_TIMEOUT=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "TIMEOUT=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		SS_DNS_ADDRS=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "DNS_ADDRS=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		SS_ARGS=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "ARGS=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
	fi
}

# 配置SS服务器监听的地址
config_ss_server_addr(){
    echo -e "请输入SS的服务器IP地址"
    read -e -p "(当前: ${SS_SERVER_ADDR}):" NEW_SS_SERVER_ADDR
    if [ ! -z "${NEW_SS_SERVER_ADDR}" ]; then
        SS_SERVER_ADDR=${NEW_SS_SERVER_ADDR}
        echo -e "${Info} SS的服务器地址已修改为 ${SS_SERVER_ADDR} !"
    fi
}

# 配置SS服务监听的端口号
config_ss_server_port(){
    echo -e "请输入SS的服务端口号"
    read -e -p "(当前: ${SS_SERVER_PORT}):" NEW_SS_SERVER_PORT
    if [ ! -z "${NEW_SS_SERVER_PORT}" ]; then
        SS_SERVER_PORT=${NEW_SS_SERVER_PORT}
        echo -e "${Info} SS的服务端口已修改为 ${SS_SERVER_PORT} !"
    fi
}

# 设置SS的连接密码
config_ss_password(){
	echo -e "请输入SS的连接密码"
    read -e -p "(当前: ${SS_PASSWORD})" NEW_SS_PASSWORD
    if [ ! -z "${NEW_SS_PASSWORD}" ]; then
        SS_PASSWORD=${NEW_SS_PASSWORD}
        echo -e "${Info} SS的连接密码已修改为 ${SS_PASSWORD} !"
    fi
}

# 设置SS的加密方法
config_ss_method(){
	echo -e "请输入SS的加密方法"
	echo -e "可以使用的加密方式有：rc4-md5,aes-128-gcm, aes-192-gcm, aes-256-gcm,aes-128-cfb, aes-192-cfb, aes-256-cfb,aes-128-ctr, aes-192-ctr, aes-256-ctr,camellia-128-cfb, camellia-192-cfb,camellia-256-cfb, bf-cfb,chacha20-ietf-poly1305,xchacha20-ietf-poly1305,salsa20, chacha20 and chacha20-ietf"
    read -e -p "(当前: ${SS_METHOD})" NEW_SS_METHOD
    if [ ! -z "${NEW_SS_METHOD}" ]; then
        SS_METHOD=${NEW_SS_METHOD}
        echo -e "${Info} SS的加密方法已修改为 ${SS_METHOD} !"
    fi
}

# 设置SS的超时
config_ss_timeout(){
	echo -e "请输入SS的超时时间"
    read -e -p "(当前: ${SS_TIMEOUT})" NEW_SS_TIMEOUT
    if [ ! -z "${NEW_SS_TIMEOUT}" ]; then
        SS_TIMEOUT=${NEW_SS_TIMEOUT}
        echo -e "${Info} SS的超时时间已修改为 ${SS_TIMEOUT} !"
    fi
}

# 设置SS的DNS服务器
config_ss_dns_addrs(){
	echo -e "请输入SS的DNS服务器"
    read -e -p "(当前: ${SS_DNS_ADDRS})" NEW_SS_DNS_ADDRS
    if [ ! -z "${NEW_SS_DNS_ADDRS}" ]; then
        SS_DNS_ADDRS=${NEW_SS_DNS_ADDRS}
        echo -e "${Info} SS的DNS服务器已修改为 ${SS_DNS_ADDRS} !"
    fi
}

# 设置SS的扩展运行参数
config_ss_args(){
	echo -e "请输入SS的其他运行参数"
    read -e -p "(当前: ${SS_ARGS})" NEW_SS_ARGS
    if [ ! -z "${NEW_SS_ARGS}" ]; then
        SS_ARGS=${NEW_SS_ARGS}
        echo -e "${Info} SS的DNS服务器已修改为 ${SS_ARGS} !"
    fi
}

# 读取UDPSpeeder Docker中的运行参数
read_udpspeeder_docker(){
	US_CONTAINER_ID=`docker ps -a |grep 'udpspeeder' | awk '{print $1}'`
	if [ -z ${US_CONTAINER_ID} ]; then 
		echo "未找到UDPSpeeder容器！"
	else 
		INSPECT_INFO=`docker inspect ${US_CONTAINER_ID}`
		US_LISTEN_IP=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "LISTEN_IP=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		US_LISTEN_PORT=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "LISTEN_PORT=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		US_TARGET_IP=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "TARGET_IP=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		US_TARGET_PORT=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "TARGET_PORT=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		US_FEC=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "FEC=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		US_KEY=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "KEY=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		US_TIMEOUT=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "TIMEOUT=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
	fi
}

# 配置UDPSpeeder服务器监听的地址
config_us_listen_ip(){
    echo -e "请输入UDPSpeeder服务器的IP地址"
    read -e -p "(当前: ${US_LISTEN_IP}):" NEW_US_LISTEN_IP
    if [ ! -z "${NEW_US_LISTEN_IP}" ]; then
        US_LISTEN_IP=${NEW_US_LISTEN_IP}
        echo -e "${Info} UDPSpeeder服务器地址已修改为 ${US_LISTEN_IP} !"
    fi
}

# 配置UDPSpeeder服务监听的端口号
config_us_listen_port(){
    echo -e "请输入UDPSpeeder服务端口号"
    read -e -p "(当前: ${US_LISTEN_PORT}):" NEW_US_LISTEN_PORT
    if [ ! -z "${NEW_US_LISTEN_PORT}" ]; then
        US_LISTEN_PORT=${NEW_US_LISTEN_PORT}
        echo -e "${Info} UDPSpeeder服务端口已修改为 ${US_LISTEN_PORT} !"
    fi
}

# 配置UDPSpeeder服务上连的地址
config_us_target_ip(){
    echo -e "请输入UDPSpeeder服务上连的地址"
    read -e -p "(当前: ${US_TARGET_IP}):" NEW_US_TARGET_IP
    if [ ! -z "${NEW_US_TARGET_IP}" ]; then
        US_TARGET_IP=${NEW_US_TARGET_IP}
        echo -e "${Info} UDPSpeeder服务上连的地址已修改为 ${US_TARGET_IP} !"
    fi
}

# 配置UDPSpeeder服务上连的端口号
config_us_target_port(){
    echo -e "请输入UDPSpeeder服务上连的端口号"
    read -e -p "(当前: ${US_TARGET_PORT}):" NEW_US_TARGET_PORT
    if [ ! -z "${NEW_US_TARGET_PORT}" ]; then
        US_TARGET_PORT=${NEW_US_TARGET_PORT}
        echo -e "${Info} UDPSpeeder服务上连的端口号已修改为 ${US_TARGET_PORT} !"
    fi
}

# 配置UDPSpeeder服务的连接密码
config_us_key(){
    echo -e "请输入UDPSpeeder的连接密码"
    read -e -p "(当前: ${US_KEY}):" NEW_US_KEY
    if [ ! -z "${NEW_US_KEY}" ]; then
        US_KEY=${NEW_US_KEY}
        echo -e "${Info} UDPSpeeder连接密码已修改为 ${US_KEY} !"
    fi
}

# 配置UDPSpeeder服务的FEC（Forward Error Correction）值
config_us_fec(){
    echo -e "请输入UDPSpeeder的FEC值"
    read -e -p "(当前: ${US_FEC}):" NEW_US_FEC
    if [ ! -z "${NEW_US_FEC}" ]; then
        US_FEC=${NEW_US_FEC}
        echo -e "${Info} UDPSpeeder的FEC值已修改为 ${US_FEC} !"
    fi
}

# 配置UDPSpeeder服务的超时值
config_us_timeout(){
    echo -e "请输入UDPSpeeder的超时值"
    read -e -p "(当前: ${US_TIMEOUT}):" NEW_US_TIMEOUT
    if [ ! -z "${NEW_US_TIMEOUT}" ]; then
        US_TIMEOUT=${NEW_US_TIMEOUT}
        echo -e "${Info} UDPSpeeder的超时值已修改为 ${US_TIMEOUT} !"
    fi
}

# 读取UDP2RAW Docker中的运行参数
read_udp2raw_docker(){
	UR_CONTAINER_ID=`docker ps -a |grep 'udp2raw' | awk '{print $1}'`
	if [ -z ${UR_CONTAINER_ID} ]; then 
		echo "未找到UDP2RAW容器！"
	else 
		INSPECT_INFO=`docker inspect ${UR_CONTAINER_ID}`
		UR_LISTEN_IP=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "LISTEN_IP=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		UR_LISTEN_PORT=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "LISTEN_PORT=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		UR_TARGET_IP=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "TARGET_IP=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		UR_TARGET_PORT=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "TARGET_PORT=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		UR_RAW_MODE=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "RAW_MODE=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		UR_KEY=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "KEY=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
		UR_ARGS=`echo ${INSPECT_INFO} | jq -r '.[].Config.Env' | jq -r '.[]' |grep "ARGS=" |sed -e 's/\(.*\)=\(.*\)/\2/g'`
	fi
}

# 配置UDP2Raw服务器监听的地址
config_ur_listen_ip(){
    echo -e "请输入UDP2Raw服务器的IP地址"
    read -e -p "(当前: ${UR_LISTEN_IP}):" NEW_UR_LISTEN_IP
    if [ ! -z "${NEW_UR_LISTEN_IP}" ]; then
        UR_LISTEN_IP=${NEW_UR_LISTEN_IP}
        echo -e "${Info} UDP2Raw服务器地址已修改为 ${UR_LISTEN_IP} !"
    fi
}

# 配置UDP2Raw服务监听的端口号
config_ur_listen_port(){
    echo -e "请输入UDP2Raw服务端口号"
    read -e -p "(当前: ${UR_LISTEN_PORT}):" NEW_UR_LISTEN_PORT
    if [ ! -z "${NEW_UR_LISTEN_PORT}" ]; then
        UR_LISTEN_PORT=${NEW_UR_LISTEN_PORT}
        echo -e "${Info} UDP2Raw服务端口已修改为 ${UR_LISTEN_PORT} !"
    fi
}

# 配置UDP2Raw服务上连的地址
config_ur_target_ip(){
    echo -e "请输入UDP2Raw服务上连的地址"
    read -e -p "(当前: ${UR_TARGET_IP}):" NEW_UR_TARGET_IP
    if [ ! -z "${NEW_UR_TARGET_IP}" ]; then
        UR_TARGET_IP=${NEW_UR_TARGET_IP}
        echo -e "${Info} UDP2Raw服务上连的地址已修改为 ${UR_TARGET_IP} !"
    fi
}

# 配置UDP2Raw服务上连的端口号
config_ur_target_port(){
    echo -e "请输入UDP2Raw服务上连的端口号"
    read -e -p "(当前: ${UR_TARGET_PORT}):" NEW_UR_TARGET_PORT
    if [ ! -z "${NEW_UR_TARGET_PORT}" ]; then
        UR_TARGET_PORT=${NEW_UR_TARGET_PORT}
        echo -e "${Info} UDP2Raw服务上连的端口号已修改为 ${UR_TARGET_PORT} !"
    fi
}

# 配置UDP2Raw服务的连接密码
config_ur_key(){
    echo -e "请输入UDP2Raw的连接密码"
    read -e -p "(当前: ${UR_KEY}):" NEW_UR_KEY
    if [ ! -z "${NEW_UR_KEY}" ]; then
        UR_KEY=${NEW_UR_KEY}
        echo -e "${Info} UDP2Raw连接密码已修改为 ${UR_KEY} !"
    fi
}

# 配置UDP2Raw服务的伪装方式
config_ur_raw_mode(){
    echo -e "请输入UDP2Raw的伪装方式"
    read -e -p "(当前: ${UR_RAW_MODE}):" NEW_UR_RAW_MODE
    if [ ! -z "${NEW_UR_RAW_MODE}" ]; then
        UR_RAW_MODE=${NEW_UR_RAW_MODE}
        echo -e "${Info} UDP2Raw的伪装方式已修改为 ${UR_RAW_MODE} !"
    fi
}

# 配置UDP2Raw服务的其他运行参数
config_ur_args(){
    echo -e "请输入UDP2Raw的其他运行参数"
    read -e -p "(当前: ${UR_ARGS}):" NEW_UR_ARGS
    if [ ! -z "${NEW_UR_ARGS}" ]; then
        UR_ARGS=${NEW_UR_ARGS}
        echo -e "${Info} UDP2Raw的其他运行参数已修改为 ${UR_ARGS} !"
    fi
}

# 安装Docker
INFO=`docker -v`
if [ -z ${INFO} ]; then
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
	add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
	apt update && apt install -y docker-ce jq
	systemctl enable docker.service
fi

# 启用BBR
enable_bbr

# DDNS设置
read_rc_local
config_ddns_host
verify_ddns

# 下载Shadowsocks Docker镜像
docker pull shadowsocks/shadowsocks-libev

# 设置SS Docker的运行参数
read_ss_docker
config_ss_server_addr
config_ss_server_port
config_ss_password
config_ss_method
config_ss_timeout
config_ss_dns_addrs
config_ss_args

# 运行SS Docker
if [ ! -z ${SS_CONTAINER_ID} ]; then
	docker rm -f ${SS_CONTAINER_ID}
fi
docker run --name=ss -d -e SERVER_ADDR=${SS_SERVER_ADDR} -e SERVER_PORT=${SS_SERVER_PORT} -e PASSWORD=${SS_PASSWORD} \
-e METHOD=${SS_METHOD} -e TIMEOUT=${SS_TIMEOUT} -e DNS_ADDRS=${SS_DNS_ADDRS} -e ARGS=${SS_ARGS} -p ${SS_SERVER_PORT}:${SS_SERVER_PORT} \
-p ${SS_SERVER_PORT}:${SS_SERVER_PORT}/udp --restart=always ${SS_ARGS} shadowsocks/shadowsocks-libev
SS_CONTAINER_ID=`docker ps -a |grep 'shadowsocks/shadowsocks-libev' | awk '{print $1}'`

##########完成SS配置，开始配置UDPSpeeder
read -e -p "是否要开启UDP加速服务（Y/N）？" ENABLE_UDP_SPEEDER
if [ ${ENABLE_UDP_SPEEDER} == "Y" || ${ENABLE_UDP_SPEEDER} == "y" ]; then
	# 拉取udpspeeder docker镜像
	docker pull ivanstang/udpspeeder

	# 读取udpspeeder docker运行参数
	read_udpspeeder_docker

	# 设置udpspeeder docker运行参数
	# 注意：TARGET IP和PORT不用设置，取SS服务监听的地址和端口号
	config_us_listen_ip
	config_us_listen_port
	config_us_key
	config_us_fec
	config_us_timeout

	# 运行UDPSpeeder Docker
	if [ -z ${US_CONTAINER_ID} ]; then
		docker rm -f ${US_CONTAINER_ID}
	fi
	docker run --name=udpspeeder -d -e LISTEN_IP=${US_LISTEN_IP} -e LISTEN_PORT=${US_LISTEN_PORT} -e TARGET_IP=${US_TARGET_IP} \
	-e TARGET_PORT=${SS_SERVER_PORT} -e FEC=${US_FEC} -e KEY=${US_KEY} -e TIMEOUT=${US_TIMEOUT} --net=container:${SS_CONTAINER_ID} \
	ivanstang/udpspeeder
	US_CONTAINER_ID=`docker ps -a |grep 'udpspeeder' | awk '{print $1}'`

	# 拉取udp2raw docker镜像
	docker pull ivanstang/udp2raw

	# 读取udp2raw docker运行参数
	read_udp2raw_docker
	config_ur_listen_ip
	config_ur_listen_port
	config_ur_key
	config_ur_raw_mode
	config_ur_args

	# 运行UDP2RAW Docker
	if [ -z ${UR_CONTAINER_ID} ]; then
		docker rm -f ${UR_CONTAINER_ID}
	fi
	docker run --name-udp2raw -d -e LISTEN_IP=${UR_LISTEN_IP} -e LISTEN_PORT=${UR_LISTEN_PORT} -e TARGET_IP=${UR_TARGET_IP} \
	-e TARGET_PORT=${US_LISTEN_PORT} -e KEY=${UR_KEY} -e RAW_MODE=${UR_RAW_MODE} ${UR_ARGS} --net=container:${SS_CONTAINER_ID} \
	ivanstang/udp2raw
	UR_CONTAINER_ID=`docker ps -a |grep 'udp2raw' | awk '{print $1}'`
fi

echo "脚本执行完毕！"


