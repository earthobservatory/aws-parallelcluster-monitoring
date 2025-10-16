#!/bin/bash -i
#
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Ubuntu-compatible version of AWS ParallelCluster monitoring setup
#

# Source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig

# Update package list
apt-get update

# Install Docker on Ubuntu
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common

# Add Docker's official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Set up the stable repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

# Start and enable Docker service
sudo ctl start docker
sudo systemctl enable docker

# Add cluster user to docker group
usermod -a -G docker $cfn_cluster_user

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/1.27.4/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install additional utilities
apt-get install -y jq

monitoring_dir_name=aws-parallelcluster-monitoring
monitoring_home="/home/${cfn_cluster_user}/${monitoring_dir_name}"

echo "$> variable monitoring_dir_name -> ${monitoring_dir_name}"
echo "$> variable monitoring_home -> ${monitoring_home}"

case "${cfn_node_type}" in
	HeadNode | MasterServer)

		# Extract configuration values
		cfn_fsx_fs_id=$(cat /etc/chef/dna.json | grep \"cfn_fsx_fs_id\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		
		# Use ec2-metadata if available, otherwise use cloud-init query
		if command -v ec2-metadata &> /dev/null; then
			master_instance_id=$(ec2-metadata -i | awk '{print $2}')
		else
			# Alternative method using IMDSv2
			TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
			master_instance_id=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
		fi
		
		cfn_max_queue_size=$(aws cloudformation describe-stacks --stack-name $stack_name --region $cfn_region | jq -r '.Stacks[0].Parameters | map(select(.ParameterKey == "MaxSize"))[0].ParameterValue')
		s3_bucket=$(echo $cfn_postinstall | sed "s/s3:\/\///g;s/\/.*//")
		cluster_s3_bucket=$(cat /etc/chef/dna.json | grep \"cluster_s3_bucket\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		cluster_config_s3_key=$(cat /etc/chef/dna.json | grep \"cluster_config_s3_key\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		cluster_config_version=$(cat /etc/chef/dna.json | grep \"cluster_config_version\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		log_group_names="\/aws\/parallelcluster\/$(echo ${stack_name} | cut -d "-" -f2-)"

		# Create necessary directories
		mkdir -p ${monitoring_home}/parallelcluster-setup

		# Download cluster configuration
		aws s3api get-object --bucket $cluster_s3_bucket --key $cluster_config_s3_key --region $cfn_region --version-id $cluster_config_version ${monitoring_home}/parallelcluster-setup/cluster-config.json

		# Install Go on Ubuntu
		apt-get install -y golang-go

		# Set proper ownership
		chown $cfn_cluster_user:$cfn_cluster_user -R /home/$cfn_cluster_user
		chmod +x ${monitoring_home}/custom-metrics/*

		# Copy custom metrics scripts
		cp -rp ${monitoring_home}/custom-metrics/* /usr/local/bin/
		
		# Install systemd service for slurm exporter
		if [ -f "${monitoring_home}/prometheus-slurm-exporter/slurm_exporter.service" ]; then
			mv ${monitoring_home}/prometheus-slurm-exporter/slurm_exporter.service /etc/systemd/system/
		fi

		# Set up cron jobs for the cluster user
		# Install cron if not present
		apt-get install -y cron
		systemctl enable cron
		systemctl start cron

		# Add cron jobs
		(crontab -l -u $cfn_cluster_user 2>/dev/null; echo "*/1 * * * * /usr/local/bin/1m-cost-metrics.sh") | crontab -u $cfn_cluster_user -
		(crontab -l -u $cfn_cluster_user 2>/dev/null; echo "*/60 * * * * /usr/local/bin/1h-cost-metrics.sh") | crontab -u $cfn_cluster_user -

		# Replace tokens in configuration files
		sed -i "s/_S3_BUCKET_/${s3_bucket}/g"               	${monitoring_home}/grafana/dashboards/ParallelCluster.json
		sed -i "s/__INSTANCE_ID__/${master_instance_id}/g"  	${monitoring_home}/grafana/dashboards/ParallelCluster.json
		sed -i "s/__FSX_ID__/${cfn_fsx_fs_id}/g"            	${monitoring_home}/grafana/dashboards/ParallelCluster.json
		sed -i "s/__AWS_REGION__/${cfn_region}/g"           	${monitoring_home}/grafana/dashboards/ParallelCluster.json

		sed -i "s/__AWS_REGION__/${cfn_region}/g"           	${monitoring_home}/grafana/dashboards/logs.json
		sed -i "s/__LOG_GROUP__NAMES__/${log_group_names}/g"    ${monitoring_home}/grafana/dashboards/logs.json

		sed -i "s/__Application__/${stack_name}/g"          	${monitoring_home}/prometheus/prometheus.yml
		sed -i "s/__AWS_REGION__/${cfn_region}/g"          		${monitoring_home}/prometheus/prometheus.yml

		sed -i "s/__INSTANCE_ID__/${master_instance_id}/g"  	${monitoring_home}/grafana/dashboards/master-node-details.json
		sed -i "s/__INSTANCE_ID__/${master_instance_id}/g"  	${monitoring_home}/grafana/dashboards/compute-node-list.json
		sed -i "s/__INSTANCE_ID__/${master_instance_id}/g"  	${monitoring_home}/grafana/dashboards/compute-node-details.json

		sed -i "s/__MONITORING_DIR__/${monitoring_dir_name}/g"  ${monitoring_home}/docker-compose/docker-compose.master.yml

		# Generate self-signed certificate for Nginx over SSL
		nginx_dir="${monitoring_home}/nginx"
		nginx_ssl_dir="${nginx_dir}/ssl"
		mkdir -p ${nginx_ssl_dir}
		
		# Get public DNS name
		if command -v ec2-metadata &> /dev/null; then
			public_dns=$(ec2-metadata -p | awk '{print $2}')
		else
			# Alternative method using IMDSv2
			TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
			public_dns=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)
		fi
		
		echo -e "\nDNS.1=${public_dns}" >> "${nginx_dir}/openssl.cnf"
		openssl req -new -x509 -nodes -newkey rsa:4096 -days 3650 -keyout "${nginx_ssl_dir}/nginx.key" -out "${nginx_ssl_dir}/nginx.crt" -config "${nginx_dir}/openssl.cnf"

		# Give $cfn_cluster_user ownership
		chown -R $cfn_cluster_user:$cfn_cluster_user "${nginx_ssl_dir}/nginx.key"
		chown -R $cfn_cluster_user:$cfn_cluster_user "${nginx_ssl_dir}/nginx.crt"

		# Start Docker Compose services for master
		/usr/local/bin/docker-compose --env-file /etc/parallelcluster/cfnconfig -f ${monitoring_home}/docker-compose/docker-compose.master.yml -p monitoring-master up -d

		# Download and build prometheus-slurm-exporter
		##### Please note this software package is under GPLv3 License #####
		# More info here: https://github.com/vpenso/prometheus-slurm-exporter/blob/master/LICENSE
		
		# Install git if not present
		apt-get install -y git build-essential
		
		cd ${monitoring_home}
		git clone https://github.com/vpenso/prometheus-slurm-exporter.git
		sed -i 's/NodeList,AllocMem,Memory,CPUsState,StateLong/NodeList: ,AllocMem: ,Memory: ,CPUsState: ,StateLong:/' prometheus-slurm-exporter/node.go
		cd prometheus-slurm-exporter
		GOPATH=/root/go-modules-cache HOME=/root go mod download
		GOPATH=/root/go-modules-cache HOME=/root go build
		mv ${monitoring_home}/prometheus-slurm-exporter/prometheus-slurm-exporter /usr/bin/prometheus-slurm-exporter

		# Reload systemd and start slurm_exporter
		systemctl daemon-reload
		systemctl enable slurm_exporter
		systemctl start slurm_exporter
	;;

	ComputeFleet)
		# Get compute instance type
		if command -v ec2-metadata &> /dev/null; then
			compute_instance_type=$(ec2-metadata -t | awk '{print $2}')
		else
			# Alternative method using IMDSv2
			TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
			compute_instance_type=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
		fi
		
		gpu_instances="[pg][2-9].*\.[0-9]*[x]*large"
		echo "$> Compute Instances Type EC2 -> ${compute_instance_type}"
		echo "$> GPUS Instances EC2 -> ${gpu_instances}"
		
		if [[ $compute_instance_type =~ $gpu_instances ]]; then
			# Install NVIDIA Docker for GPU instances
			distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
			
			# Add NVIDIA Docker repository
			curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-docker-archive-keyring.gpg
			curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
				sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-docker-archive-keyring.gpg] https://#g' | \
				tee /etc/apt/sources.list.d/nvidia-docker.list
			
			apt-get update
			apt-get install -y nvidia-docker2
			systemctl restart docker
			
			# Start GPU monitoring stack
			/usr/local/bin/docker-compose -f /home/${cfn_cluster_user}/${monitoring_dir_name}/docker-compose/docker-compose.compute.gpu.yml -p monitoring-compute up -d
		else
			# Start regular compute monitoring stack
			/usr/local/bin/docker-compose -f /home/${cfn_cluster_user}/${monitoring_dir_name}/docker-compose/docker-compose.compute.yml -p monitoring-compute up -d
		fi
	;;
esac

echo "AWS ParallelCluster monitoring setup completed for Ubuntu"
