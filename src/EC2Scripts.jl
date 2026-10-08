module EC2Scripts

using ReadWriteFind, Printf

# EC2 differs from a DigitalOcean droplet in how you log in:
#   - the login user is not root: "ubuntu" (Ubuntu AMIs), "ec2-user" (Amazon Linux / RHEL), ...
#   - authentication is usually a .pem key pair file, passed with `key_file`
#     (leave it as `nothing` if the key is already set up in ~/.ssh/config or ssh-agent)
#   - the public IP changes every stop/start unless an Elastic IP is attached,
#     so `host` can be an IP, a public DNS name, or a Host alias from ~/.ssh/config

function ssh_options(key_file)
    # accept-new: trust a host key the first time we see it (new instances), but still
    # refuse if a known host's key changes
    opts = ["-o", "StrictHostKeyChecking=accept-new"]
    if !isnothing(key_file)
        append!(opts, ["-i", key_file])
    end
    return opts
end

# Home directory of the login user on the instance, e.g. for absolute paths written into
# input files (where "~" is not expanded): replace(remote_working_directory, "~" => remote_home(user))
remote_home(user) = user == "root" ? "/root" : "/home/$user"

function generate_instance_script(remote_working_directory, model_names, local_working_directory, bash_filename, cpus; add_queue_logic=false)
    lines = []

    push!(lines, "#!/bin/bash")
    push!(lines, "# Generated for AWS EC2 instance")
    push!(lines, @sprintf "cd %s" remote_working_directory)

    if add_queue_logic
        add_submission_to_queue!(lines)
    end

    # Abaqus execution lines
    for i in eachindex(model_names)
        line = "abaqus job=" * model_names[i] * " cpus=$cpus" * " interactive"
        push!(lines, line)
    end

    ReadWriteFind.write_file(joinpath(local_working_directory, bash_filename), lines)
end

function generate_instance_script_with_UEL(remote_working_directory, model_names, local_working_directory, bash_filename, uel_filename, cpus; add_queue_logic=false)
    lines = []

    push!(lines, "#!/bin/bash")
    push!(lines, "# Generated for AWS EC2 instance")
    push!(lines, @sprintf "cd %s" remote_working_directory)
    # Instances typically don't have a licensed Intel Fortran compiler installed.
    # This tells Abaqus's own lnx86_64.env to compile/link user subroutines with
    # gfortran instead of ifort (a switch SIMULIA ships for grid/cloud nodes).
    push!(lines, "export ABQ_USUB_GFORTRAN=1")
    # The default open-file-descriptor limit (often 1024) can be exhausted on
    # long, contact-heavy analyses - Abaqus's own internal file handles plus any
    # per-element UEL output files can approach that ceiling over many increments.
    # Raise it to the session's hard limit (safe - doesn't require root/sysadmin
    # config changes, only raises up to what's already permitted).
    push!(lines, "ulimit -n \$(ulimit -Hn)")

    if add_queue_logic
        add_submission_to_queue!(lines)
    end

    # Abaqus execution lines
    for i in eachindex(model_names)
        line = "abaqus job=" * model_names[i] * " user=" * uel_filename * " cpus=$cpus" * " interactive"
        push!(lines, line)
    end

    ReadWriteFind.write_file(joinpath(local_working_directory, bash_filename), lines)
end

function add_submission_to_queue!(lines)
    push!(lines, "")
    push!(lines, "# --- Queue logic: wait if another Abaqus job is running ---")
    push!(lines, "CID_FILE=\$(find ~ -name \"*.cid\" 2>/dev/null | head -1)")
    push!(lines, "RUNNING_PID=\$([ -n \"\$CID_FILE\" ] && head -1 \"\$CID_FILE\")")
    push!(lines, "")
    push!(lines, "if [ -n \"\$RUNNING_PID\" ] && kill -0 \$RUNNING_PID 2>/dev/null; then")
    push!(lines, "    echo \"Job running (PID \$RUNNING_PID). Waiting in queue...\"")
    push!(lines, "    while kill -0 \$RUNNING_PID 2>/dev/null; do sleep 60; done")
    push!(lines, "    echo \"Previous job done. Starting now...\"")
    push!(lines, "fi")
    push!(lines, "# --- End queue logic ---")
    push!(lines, "")
end


function create_remote_directory(host, remote_working_directory; user="ubuntu", key_file=nothing)
    opts = ssh_options(key_file)

    #### Create remote working directory if it doesn't exist
    check_cmd = "[ -d $remote_working_directory ] && echo 'exists' || mkdir -p $remote_working_directory"

    result = read(`ssh $opts $user@$host $check_cmd`, String)

    if occursin("exists", result)
        println("Directory already exists: $remote_working_directory (Skipping creation)")
    else
        println("Created new directory: $remote_working_directory")
    end
end

function upload_file(host, local_file, remote_working_directory; user="ubuntu", key_file=nothing)
    opts = ssh_options(key_file)
    run(`scp $opts $local_file $user@$host:$remote_working_directory/`)
    println("Uploaded: $(basename(local_file))")
end

function deploy_to_instance(host, remote_working_directory, local_working_directory, bash_filename, model_names; user="ubuntu", key_file=nothing)
    println("--- Starting Deployment to EC2 Instance ---")

    create_remote_directory(host, remote_working_directory; user, key_file)

    #### Upload the .sh script
    upload_file(host, joinpath(local_working_directory, bash_filename), remote_working_directory; user, key_file)

    #### Upload .inp files
    for name in model_names
        upload_file(host, joinpath(local_working_directory, "$name.inp"), remote_working_directory; user, key_file)
    end

    println("--- Deployment Complete ---")
end

function deploy_to_instance_with_UEL(host, remote_working_directory, local_working_directory, bash_filename, uel_filename, model_names; user="ubuntu", key_file=nothing)
    println("--- Starting Deployment to EC2 Instance ---")

    create_remote_directory(host, remote_working_directory; user, key_file)

    #### Upload the .sh script
    upload_file(host, joinpath(local_working_directory, bash_filename), remote_working_directory; user, key_file)

    #### Upload the UEL Fortran file
    upload_file(host, joinpath(local_working_directory, uel_filename), remote_working_directory; user, key_file)

    #### Upload .inp files
    for name in model_names
        upload_file(host, joinpath(local_working_directory, "$name.inp"), remote_working_directory; user, key_file)
    end

    println("--- Deployment Complete ---")
end

function download_files(host, remote_dir, local_dir, file_extension; user="ubuntu", key_file=nothing)

    local_file_path = joinpath(local_dir, file_extension)

    if !isdir(local_file_path)
        mkpath(local_file_path)
    end

    opts = ssh_options(key_file)
    remote_source = "$(user)@$(host):$(remote_dir)/*.$file_extension"

    println("Downloading .$file_extension files from $host...")

    try

        run(`scp -C $opts $remote_source $local_file_path`)

        println("Download complete!")

    catch e
        @error "Download failed." exception=e
    end
end

download_dat_files(host, remote_dir, local_dir; user="ubuntu", key_file=nothing) = download_files(host, remote_dir, local_dir, "dat"; user, key_file)

end
