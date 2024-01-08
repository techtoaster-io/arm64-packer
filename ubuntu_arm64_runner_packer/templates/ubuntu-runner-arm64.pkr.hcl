locals {
  ecr_repo      = "${var.ecr_repo}"
  ecr_image_tag = var.image_tag_suffix == "-test" ? "${var.image_tag_prefix}${var.image_tag_suffix}" : "${var.image_tag_prefix}"
  registry      = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}


variable "runner_user_uid" {
  type    = string
  default = "1000"
}

variable "runner_user_gid" {
  type    = string
  default = "1000"
}

variable "image_tag_suffix" {
  type    = string
  default = "sandpit"
}


variable "target_platform" {
  type    = string
  default = "linux/arm64"
}

variable "runner_user" {
  type    = string
  default = "ubuntu"
}

variable "docker_group_gid" {
  type    = string
  default = "993"
}

variable "docker_group_name" {
  type    = string
  default = "docker"
}

variable "runner_version" {
  type    = string
  default = "2.311.0"
}

variable "dumb_init_version" {
  type    = string
  default = "1.2.5"
}

variable "agent_toolsdirectory" {
  type    = string
  default = "/opt/hostedtoolcache"
}

variable "runner_assets_dir" {
  type    = string
  default = "/runnertmp"
}

variable "aws_account_id" {
  type    = string
  default = ""
}

variable "aws_region" {
  type    = string
  default = ""
}

variable "ecr_repo" {
  type    = string
  default = ""
}

variable "image_tag_prefix" {
  type    = string
  default = "ubuntu-jammy-arm64"
}

variable "image_folder" {
  type    = string
  default = "/imagegeneration"
}

variable "image_os" {
  type    = string
  default = "ubuntu-arm64"
}

source "docker" "arm64" {
  image    = "docker.io/arm64v8/ubuntu:latest"
  commit   = true
  platform = "linux/arm64/v8"
  pull     = true
  changes = [
    "USER ${var.runner_user}",
    "ENTRYPOINT [\"/bin/bash\", \"-c\"]",
    "CMD [\"entrypoint.sh\"]",
    "ENV AGENT_TOOLSDIRECTORY /opt/hostedtoolcache",
    "ENV LC_ALL C",
    "ENV DEBIAN_FRONTEND noninteractive",
    "ENV DEBCONF_NONINTERACTIVE_SEEN true",
    "ENV RUNNER_USER ${var.runner_user}",
    "ENV RUNNER_HOME /${var.runner_user}",
    "ENV HOME /home/${var.runner_user}",
    "ENV TARGETPLATFORM ${var.target_platform}",
    "ENV TZ \"Australia/Sydney\"",
    "ENV RUNNER_VERSION ${var.runner_version}",
    "ENV RUNNER_ASSETS_DIR ${var.runner_assets_dir}",
    "VOLUME /var/lib/docker",
    "ENV PATH $PATH:/home/${var.runner_user}/.local/bin:/${var.runner_user}"
  ]
}

build {
  sources = ["source.docker.arm64"]

  provisioner "shell" {
    inline = [
      "echo set debconf to Noninteractive",
    "echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections"]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
      apt-get update -y \
      && apt-get upgrade -y \
      && apt-get install -y --no-install-recommends \
      curl \
      tzdata \
      jq \
      ca-certificates \
      apt-utils \
      apt-transport-https \
      software-properties-common \
      build-essential \
      wget \
      git \
      iptables \
      ssh \
      gnupg \
      zip \
      unzip \
      lsb-release \
      sudo \
      && apt-get autoremove -y \
      && apt-get autoclean -y \
      && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      EOT
    ]
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["mkdir ${var.image_folder}", "chmod 777 ${var.image_folder}"]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
      curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | bash \
      && apt-get install -y --no-install-recommends git-lfs
      EOT
    ]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
        if [ "$(getent group ${var.docker_group_name} | cut -d: -f1)" = "${var.docker_group_name}" ] ; then \
        groupdel $(getent group ${var.docker_group_name} | cut -d: -f1) ; \
        fi \
        && groupadd -g ${var.docker_group_gid} ${var.docker_group_name}
      EOT
    ]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
        if [ "$(getent group ${var.runner_user_gid} | cut -d: -f3)" = "${var.runner_user_gid}" ] ; then \
        groupdel $(getent group ${var.runner_user_gid} | cut -d: -f1) ; \
        fi \
        && addgroup --system --gid ${var.runner_user_gid} ${var.runner_user}        
      EOT
    ]
  }


  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
      adduser --system --home /home/${var.runner_user} --uid ${var.runner_user_gid} --gecos "" --gid ${var.runner_user_gid} --disabled-password ${var.runner_user} \
      && usermod -aG sudo ${var.runner_user} \
      && usermod -aG ${var.docker_group_name} ${var.runner_user} \
      && echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers \
      && echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers \
      && chmod 0440  /etc/sudoers
    EOT
    ]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
    export ARCH=$(echo ${var.target_platform} | cut -d / -f2) \
      && wget https://github.com/Yelp/dumb-init/releases/download/v${var.dumb_init_version}/dumb-init_${var.dumb_init_version}_$${ARCH}.deb \
      && dpkg -i dumb-init_*.deb
    EOT
    ]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
      export ARCH=$(echo ${var.target_platform} | cut -d / -f2) \
        && if [ "$ARCH" = "arm64" ]; then export ARCH=arm64 ; fi \
        && if [ "$ARCH" = "amd64" ] || [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "i386" ]; then export ARCH=x64 ; fi \
        && mkdir -p "${var.runner_assets_dir}" \
        && cd "${var.runner_assets_dir}" \
        && curl -fLo runner.tar.gz https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-$${ARCH}-${var.runner_version}.tar.gz \
        && tar xzf ./runner.tar.gz \
        && rm -f runner.tar.gz \
        && ./bin/installdependencies.sh \
        && apt-get install -y libyaml-dev \
        && rm -rf /var/lib/apt/lists/*
    EOT
    ]
  }

  # https://github.com/actions/setup-python/issues/459#issuecomment-1182946401
  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "mkdir -p ${var.agent_toolsdirectory}",
      "chown ${var.runner_user}:${var.docker_group_name} ${var.agent_toolsdirectory}",
    "chmod g+rwx ${var.agent_toolsdirectory}"]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
      curl -L -o /tmp/powershell.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.3.9/powershell-7.3.9-linux-arm64.tar.gz \
      && mkdir -p /opt/microsoft/powershell/7 \
      && tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 \
      && chmod +x /opt/microsoft/powershell/7/pwsh \
      && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
      EOT
    ]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
      curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" \
      && unzip awscliv2.zip \
      && ./aws/install \
      && rm awscliv2.zip
      EOT
    ]
  }

  provisioner "file" {
    destination = "${var.image_folder}"
    sources = [
      "${path.root}/../tools"
    ]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
      mkdir -p /etc/docker \
      && cp ${var.image_folder}/tools/ubuntu_docker/daemon.json /etc/docker/daemon.json \
      && cp ${var.image_folder}/tools/ubuntu_docker/entrypoint.sh \
        ${var.image_folder}/tools/ubuntu_docker/startup.sh \
        ${var.image_folder}/tools/ubuntu_docker/logger.sh \
        ${var.image_folder}/tools/ubuntu_docker/graceful-stop.sh \
        ${var.image_folder}/tools/ubuntu_docker/wait.sh \
        ${var.image_folder}/tools/ubuntu_docker/update-status \
        /usr/bin/ \
      && chmod +x /usr/bin/entrypoint.sh /usr/bin/startup.sh /usr/bin/logger.sh /usr/bin/graceful-stop.sh /usr/bin/wait.sh /usr/bin/update-status \
      && cp ${var.image_folder}/tools/ubuntu_docker/docker-exec.sh /usr/local/bin/docker \
      && chmod +x /usr/local/bin/docker \
      && mkdir -p /etc/actions-runner \
      && cp -r ${var.image_folder}/tools/ubuntu_docker/hooks /etc/actions-runner/hooks \
      && chmod -R +x /etc/actions-runner/hooks
    EOT

    ]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
      wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/arm64/containerd.io_1.6.9-1_arm64.deb \
      && wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/arm64/docker-ce-cli_24.0.7-1~ubuntu.22.04~jammy_arm64.deb \
      && wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/arm64/docker-ce_24.0.7-1~ubuntu.22.04~jammy_arm64.deb \
      && wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/arm64/docker-buildx-plugin_0.11.2-1~ubuntu.22.04~jammy_arm64.deb \
      && wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/arm64/docker-compose-plugin_2.21.0-1~ubuntu.22.04~jammy_arm64.deb \
      && dpkg -i ./containerd.io_1.6.9-1_arm64.deb \
      ./docker-ce_24.0.7-1~ubuntu.22.04~jammy_arm64.deb \
      ./docker-ce-cli_24.0.7-1~ubuntu.22.04~jammy_arm64.deb \
      ./docker-buildx-plugin_0.11.2-1~ubuntu.22.04~jammy_arm64.deb \
      ./docker-compose-plugin_2.21.0-1~ubuntu.22.04~jammy_arm64.deb \
      && rm ./docker-ce_24.0.7-1~ubuntu.22.04~jammy_arm64.deb \
      ./docker-ce-cli_24.0.7-1~ubuntu.22.04~jammy_arm64.deb \
      ./docker-buildx-plugin_0.11.2-1~ubuntu.22.04~jammy_arm64.deb \
      ./docker-compose-plugin_2.21.0-1~ubuntu.22.04~jammy_arm64.deb
    EOT
    ]
  }

  provisioner "shell" {
    execute_command = "sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      <<EOT
    export PATH="$${PATH}:/home/${var.runner_user}/.local/bin:/${var.runner_user}" \
    && export ImageOS=${var.image_os} \
    && echo "PATH=$${PATH}" >> /etc/environment \
    && echo "ImageOS=${var.image_os}" >> /etc/environment
    EOT
    ]
  }

  post-processors {
    post-processor "docker-tag" {
      repository = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.ecr_repo}"
      tags       = ["${local.ecr_image_tag}"]
    }
  }

}

