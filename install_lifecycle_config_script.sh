#!/bin/bash
# This script installs the idle notebook auto-checker server extension to SageMaker Studio
# The original extension has a lab extension part where users can set the idle timeout via a Jupyter Lab widget.
# In this version the script installs the server side of the extension only. The idle timeout
# can be set via a command-line script which will be also created by this create and places into the
# user's home folder
#
# Installing the server side extension does not require Internet connection (as all the dependencies are stored in the
# install tarball) and can be done via VPCOnly mode.

set -eux

# specify respective timeouts for cpu and gpu in minutes
export TIMEOUT_CPU_IN_MINS=360
export TIMEOUT_GPU_IN_MINS=60

# Should already be running in user home directory, but just to check:
cd /home/sagemaker-user

# By working in a directory starting with ".", we won't clutter up users' Jupyter file tree views
mkdir -p .auto-shutdown

# Create the command-line script for setting the idle timeout
cat > .auto-shutdown/set-time-interval.sh << EOF
#!/opt/conda/bin/python
import json
import requests
TIMEOUT_CPU=${TIMEOUT_CPU_IN_MINS}
TIMEOUT_GPU=${TIMEOUT_GPU_IN_MINS}
session = requests.Session()
# Getting the xsrf token first from Jupyter Server
response = session.get("http://localhost:8888/jupyter/default/tree")
# calls the idle_checker extension's interface to set the timeout value
response = session.post("http://localhost:8888/jupyter/default/sagemaker-studio-autoshutdown/idle_checker",
            json={"idle_time_cpu": TIMEOUT_CPU, "idle_time_gpu": TIMEOUT_GPU, "keep_terminals": False},
            params={"_xsrf": response.headers['Set-Cookie'].split(";")[0].split("=")[1]})
if response.status_code == 200:
    print("Succeeded, idle timeout for CPU set to {} minutes, idle timeout for GPU set to {} minutes".format(TIMEOUT_CPU, TIMEOUT_GPU))
else:
    print("Error!")
    print(response.status_code)
EOF
chmod +x .auto-shutdown/set-time-interval.sh

# "wget" is not part of the base Jupyter Server image, you need to install it first if needed to download the tarball
sudo yum install -y wget
# You can download the tarball from GitHub or alternatively, if you're using VPCOnly mode, you can host on S3
wget -O .auto-shutdown/extension.tar.gz https://github.com/windrichie/sagemaker-studio-auto-shutdown-extension-gpu-custom/raw/main/sagemaker_studio_autoshutdown-0.1.5-gpu-custom.tar.gz

# Or instead, could serve the tarball from an S3 bucket in which case "wget" would not be needed:
# aws s3 cp s3://<S3 Bucket>/sagemaker_studio_autoshutdown-0.1.5-gpu-custom.tar.gz .auto-shutdown/extension.tar.gz

# Installs the extension
cd .auto-shutdown
tar xzf extension.tar.gz
cd sagemaker_studio_autoshutdown-0.1.5-gpu-custom

# Activate studio environment just for installing extension
export AWS_SAGEMAKER_JUPYTERSERVER_IMAGE="${AWS_SAGEMAKER_JUPYTERSERVER_IMAGE:-'jupyter-server'}"
if [ "$AWS_SAGEMAKER_JUPYTERSERVER_IMAGE" = "jupyter-server-3" ] ; then
    eval "$(conda shell.bash hook)"
    conda activate studio
fi;
pip install --no-dependencies --no-build-isolation -e .
jupyter serverextension enable --py sagemaker_studio_autoshutdown
if [ "$AWS_SAGEMAKER_JUPYTERSERVER_IMAGE" = "jupyter-server-3" ] ; then
    conda deactivate
fi;

# Restarts the jupyter server
nohup supervisorctl -c /etc/supervisor/conf.d/supervisord.conf restart jupyterlabserver

# Waiting for 30 seconds to make sure the Jupyter Server is up and running
sleep 30

# Calling the script to set the idle-timeout and active the extension
/home/sagemaker-user/.auto-shutdown/set-time-interval.sh