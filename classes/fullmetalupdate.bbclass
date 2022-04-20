# The default password for hawkbit server
HAWKBIT_USER_PASSWORD ??= "admin:admin"

ENABLE_PUSH_SERVER ??= "no"

python __anonymous() {
    import configparser
    import os

    ostree_repo = d.getVar('OSTREE_REPO')
    if not ostree_repo:
        raise bb.parse.SkipRecipe("OSTREE_REPO should be set in your local.conf")

    ostree_repo = d.getVar('OSTREE_BRANCHNAME')
    if not ostree_repo:
        raise bb.parse.SkipRecipe("OSTREE_BRANCHNAME should be set in your local.conf")

    config_file = d.getVar('HAWKBIT_CONFIG_FILE')
    if not config_file:
        raise bb.parse.SkipRecipe("Please export/define HAWKBIT_CONFIG_FILE")

    if not os.path.isfile(config_file):
        raise bb.parse.SkipRecipe("HAWKBIT_CONFIG_FILE(" + config_file + ") is not a file, please fix the path ", config_file)

    if config_file == d.expand("${LAYER_PATH_lat-layer}/recipes-sota/fullmetalupdate/files/config.cfg.sample"):
        bb.warn('Default config.cfg.sample may not work, please define a new one with HAWKBIT_CONFIG_FILE')

    if oe.types.boolean(d.getVar('ENABLE_PUSH_SERVER')):
        hawkbit_user_passwd = d.getVar('HAWKBIT_USER_PASSWORD')
        if not hawkbit_user_passwd:
            raise bb.parse.SkipRecipe("ENABLE_PUSH_SERVER is set, but HAWKBIT_USER_PASSWORD is not set")
        if hawkbit_user_passwd == "admin:admin":
            bb.warn('Default HAWKBIT_USER_PASSWORD is insecure, please define a new one according to hawkbit server')

    config = configparser.ConfigParser()
    config.read(config_file)

    server_host_name = config['server']['server_host_name']
    hawkbit_vendor_name = config['client']['hawkbit_vendor_name']
    hawkbit_url_port = config['client']['hawkbit_url_port']
    hawkbit_ssl = config['client'].getboolean('hawkbit_ssl', fallback=False)
    ostree_name_remote = config['ostree']['ostree_name_remote']
    ostree_gpg_verify = config['ostree'].getboolean('ostree_gpg-verify', fallback=False)
    ostree_ssl = config['ostree'].getboolean('ostree_ssl', fallback=False)
    ostree_url_port = config['ostree']['ostree_url_port']
    ostreepush_ssh_port = config['ostree']['ostreepush_ssh_port']
    ostreepush_ssh_user = config['ostree']['ostreepush_ssh_user']
    ostreepush_ssh_pwd = config['ostree']['ostreepush_ssh_pwd']
    hawkbit_hostname = server_host_name
    ostree_hostname = server_host_name

    if ostree_ssl:
        ostree_http_address = "https://" + ostree_hostname + ":" + ostree_url_port
    else:
        ostree_http_address = "http://" + ostree_hostname + ":" + ostree_url_port

    if hawkbit_ssl:
        hawkbit_http_address = "https://" + hawkbit_hostname + ":" + hawkbit_url_port
    else:
        hawkbit_http_address = "http://" + hawkbit_hostname + ":" + hawkbit_url_port

    ostree_http_distant_address = "http://" + server_host_name + ":" + ostree_url_port
    ostree_ssh_address = "ssh://" + ostreepush_ssh_user + "@" + ostree_hostname + ":" + ostreepush_ssh_port + "/ostree/repo"

    d.setVar('HAWKBIT_VENDOR_NAME', hawkbit_vendor_name)
    d.setVar('HAWKBIT_URL_PORT', hawkbit_url_port)
    d.setVar('HAWKBIT_SSL', hawkbit_ssl)
    d.setVar('OSTREE_OSNAME', ostree_name_remote)
    d.setVar('HAWKBIT_HOSTNAME', hawkbit_hostname)
    d.setVar('OSTREE_HOSTNAME', ostree_hostname)
    d.setVar('OSTREE_URL_PORT', ostree_url_port)
    d.setVar('OSTREEPUSH_SSH_PORT', ostreepush_ssh_port)
    d.setVar('OSTREEPUSH_SSH_USER', ostreepush_ssh_user)
    d.setVar('OSTREEPUSH_SSH_PWD', ostreepush_ssh_pwd)
    d.setVar('OSTREE_HTTP_ADDRESS', ostree_http_address)
    d.setVar('OSTREE_HTTP_DISTANT_ADDRESS', ostree_http_distant_address)
    d.setVar('OSTREE_SSH_ADDRESS', ostree_ssh_address)
    d.setVar('HAWKBIT_HTTP_ADDRESS', hawkbit_http_address)

    d.setVar('OSTREE_MIRROR_PULL_RETRIES', "10")
    d.setVar('OSTREE_MIRROR_PULL_DEPTH', "0")
    d.setVar('OSTREE_CONTAINER_PULL_DEPTH', "1")
}

ostree_init() {
    local ostree_repo="$1"
    local ostree_repo_mode="$2"

    ostree --repo=${ostree_repo} init --mode=${ostree_repo_mode}
}

ostree_init_if_non_existent() {
    local ostree_repo="$1"
    local ostree_repo_mode="$2"

    if [ ! -d ${ostree_repo} ]; then
        bbnote "init ostree repo"
        mkdir -p ${ostree_repo}
        ostree_init ${ostree_repo} ${ostree_repo_mode}
    fi
}

ostree_push() {
    local ostree_repo="$1"
    local ostree_branch="$2"

    bbnote "Push the build result to the remote OSTREE"
    sshpass -p ${OSTREEPUSH_SSH_PWD} ostree-push --sshoption "-o StrictHostKeyChecking=no" --repo ${ostree_repo} ${OSTREE_SSH_ADDRESS} ${ostree_branch}
}

ostree_pull() {
    local ostree_repo="$1"
    local ostree_branch="$2"
    local ostree_depth="$3"

    ostree pull ${ostree_branch} ${ostree_branch} --depth=${ostree_depth} --repo=${ostree_repo}
}

ostree_pull_mirror() {
    local ostree_repo="$1"
    local ostree_branch="$2"
    local ostree_depth="$3"
    local ostree_maxretry="$4"
    local lookup_timeout="Timeout"
    local loopkup_notfound="Not Found"
    local counter_retry=0

    msg=$(ostree pull ${ostree_branch} ${ostree_branch} --depth=${ostree_depth} --mirror --repo=${ostree_repo} 2>&1)
    if [ $? -eq 0 ]; then
        bbnote "OsTree pull successfully"
        return 0
    elif echo "$msg" | grep -q "${loopkup_notfound}"; then
        bbnote "OsTree remote branch not exist"
        return 0
    elif echo "$msg" | grep -q "${lookup_timeout}"; then
        while ! test $? -gt 0 && [ ${counter_retry} -le ${ostree_maxretry} ]
        do
            counter_retry=$(expr $counter_retry + 1)
            bbnote "OsTree pull counter retry: ${counter_retry}"
            msg=$(ostree pull ${ostree_branch} ${ostree_branch} --depth=${ostree_depth} --mirror --repo=${ostree_repo} 2>&1)
            if [ $? -eq 0 ]; then
                bbnote "OsTree pull successfully"
                return 0
            else
                echo "${msg}" | grep -q "${lookup_timeout}"
            fi
        done
        bbfatal "OsTree pull failed since ${msg}"
    else
        bbfatal "OsTree pull failed since ${msg}"
    fi
}

ostree_revparse() {
    local ostree_repo="$1"
    local ostree_branch="$2"

    ostree rev-parse ${ostree_branch} --repo=${ostree_repo} | head
}

ostree_remote_add() {
    local ostree_repo="$1"
    local ostree_branch="$2"
    local ostree_http_address="$3"
    bbnote "remote add $ostree_branch"
    ostree remote add --no-gpg-verify ${ostree_branch} ${ostree_http_address} --repo=${ostree_repo}
}

ostree_remote_delete() {
    local ostree_repo="$1"
    local ostree_branch="$2"

    ostree remote delete ${ostree_branch} --repo=${ostree_repo}
}

ostree_remote_update() {
   local ostree_repo="$1"
   local ostree_branch="$2"
   local ostree_http_address="$3"

   if ! ostree_is_remote_present ${ostree_repo} ${ostree_branch}; then
       ostree_remote_add ${ostree_repo} ${ostree_branch} ${ostree_http_address}
   else
       local current_url=$(ostree remote show-url ${ostree_branch} --repo ${ostree_repo})
       if [ "${current_url}" != "${ostree_http_address}" ];  then
           bbnote "Remote $ostree_branch url update from ${current_url} to ${ostree_http_address}"
           ostree_remote_delete ${ostree_repo} ${ostree_branch}
           ostree_remote_add ${ostree_repo} ${ostree_branch} ${ostree_http_address}
       fi
   fi
}

ostree_is_remote_present() {
    local ostree_repo="$1"
    local ostree_branch="$2"

    for line in $(ostree remote list --repo=${ostree_repo})
    do
        if [ "${line}" =  "${ostree_branch}" ]; then
            return 0
        fi
    done
    return 1
}

ostree_remote_add_if_not_present() {
    local ostree_repo="$1"
    local ostree_branch="$2"
    local ostree_http_address="$3"

    if ! ostree_is_remote_present ${ostree_repo} ${ostree_branch}; then
        ostree_remote_add ${ostree_repo} ${ostree_branch} ${ostree_http_address}
    fi
}

curl_post() {
    local hawkbit_rest="$1"
    local hawkbit_data="$2"

    curl "${HAWKBIT_HTTP_ADDRESS}/rest/v1/softwaremodules/${hawkbit_rest}" -i -X POST --user ${HAWKBIT_USER_PASSWORD} -H "Content-Type: application/hal+json;charset=UTF-8" -d "${hawkbit_data}"
}

hawkbit_metadata_value() {
    local key="$1"
    local value="$2"

    echo '[ { "targetVisible" : true, "value" : "'${value}'", "key" : "'${key}'" } ]'
}
