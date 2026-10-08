# EC2Scripts.jl
EC2Scripts automates running Abaqus jobs on an AWS EC2 instance. It generates a bash script that changes to a specified remote working directory and executes one or more Abaqus .inp models using a given number of CPUs. It also handles deployment by creating the remote directory (if needed) and uploading the run script, input files and UEL Fortran file to the instance via SSH/SCP, and downloading result files back.

It mirrors [DigitalOceanScripts.jl](https://github.com/runtosolve/DigitalOceanScripts.jl), with the EC2 login differences handled by keyword arguments:

- `user` — login user on the instance (default `"ubuntu"`; use `"ec2-user"` for Amazon Linux / RHEL AMIs)
- `key_file` — path to the instance's `.pem` key pair file (default `nothing`, i.e. use `~/.ssh/config` / ssh-agent)

`host` can be the instance's public IP, its public DNS name, or a `Host` alias from `~/.ssh/config`. The public IP changes every time the instance is stopped and started unless an Elastic IP is attached.

## Example

```julia
using EC2Scripts

host = "54.123.45.67"   # EC2 public IP
user = "ubuntu"
key_file = raw"C:\Users\me\.ssh\abaqus-ec2.pem"

remote_working_directory = "~/disk_volume/Projects/MyProject/r1"
local_working_directory = raw"G:\...\model_runs\r1"
bash_filename = "run_job.sh"
uel_filename = "primewall_uel.f"
model_names = ["MyModel_r1"]
cpus = 2

EC2Scripts.generate_instance_script_with_UEL(remote_working_directory, model_names, local_working_directory, bash_filename, uel_filename, cpus)
EC2Scripts.deploy_to_instance_with_UEL(host, remote_working_directory, local_working_directory, bash_filename, uel_filename, model_names; user, key_file)

# after the job finishes
EC2Scripts.download_files(host, remote_working_directory, local_working_directory, "dat"; user, key_file)
```

Absolute paths written into input files (where `~` is not expanded) can use `remote_home(user)`:

```julia
uel_output_path = replace(remote_working_directory, "~" => EC2Scripts.remote_home(user)) * "/"
```

## Function map from DigitalOceanScripts

| DigitalOceanScripts | EC2Scripts |
|---|---|
| `generate_droplet_script` | `generate_instance_script` |
| `generate_droplet_script_with_UEL` | `generate_instance_script_with_UEL` |
| `deploy_to_droplet` | `deploy_to_instance` |
| `deploy_to_droplet_with_UEL` | `deploy_to_instance_with_UEL` |
| `download_files`, `download_dat_files` | same names, plus `user` / `key_file` keywords |
