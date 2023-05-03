#!/bin/bash

set -e

# -----------------------------------------------------------------------------
# Colors

ALL_OFF="\e[0m"
BOLD="\e[1m"
BLUE="${BOLD}\e[34m"
GREEN="${BOLD}\e[32m"
PURPLE="${BOLD}\e[35m"
RED="${BOLD}\e[31m"
readonly ALL_OFF BOLD BLUE GREEN PURPLE RED

msg() {
    local mesg=$1; shift
    printf "${GREEN}==>${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@"
}

msg2() {
    local mesg=$1; shift
    printf "${BLUE}  =>${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@"
}

msg3() {
    local mesg=$1; shift
    printf "${PURPLE}    ->${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@"
}

error() {
    local mesg=$1; shift
    printf "${RED}==> $(gettext "ERROR:")${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

# -----------------------------------------------------------------------------
# Dependency check

is_installed() {
    FOUND=0

    for dep in "$@"; do
        if command -v "$dep" >/dev/null 2>/dev/null; then
            FOUND=1
            break
        fi
    done

    if [[ $FOUND -eq 0 ]]; then
        error "Could not find (at least one of) the following dependencies" "$@" >&2
        return 1
    fi

    return 0
}

installed_or_exit() {
    if ! is_installed "$@"; then
        exit 1
    fi
}

# -----------------------------------------------------------------------------

prepare() {
    msg2 "Preparing build image"

    msg3 "Installing base development packages"
    echo "CacheDir=/pacmanCache" >> /etc/pacman.conf
    echo "ParallelDownloads = ${PACMAN_PARALLEL_DOWNLOADS:-1}" >> /etc/pacman.conf
    pacman -Suy --noconfirm base-devel sudo devtools git rsync >/dev/null

    msg3 "Creating build user and build directories"
    useradd ci -M
    echo "ci ALL= NOPASSWD: /usr/bin/pacman" >> /etc/sudoers
    mkdir -p /home/ci/{,pkgdest,build,srcdest,srcpkgdest,aurdir,remote}
    chown -R ci:ci /home/ci
    chmod -R 777 /home/ci

    msg3 "Initializing gpg key"
    if [ -z ${GPG_KEY+x} ]; then
        error "GPG_KEY not set"
        exit 1
    fi

    echo "${GPG_KEY}" | sed 's@\\n@\n@g' > /tmp/sign.key
    chmod 444 /tmp/sign.key
    sudo -u ci gpg --import /tmp/sign.key >/dev/null 2>/dev/null
    gpg --import --import-options show-only /tmp/sign.key 2>/dev/null | head -n 2 | tail -n 1 | tr -d ' ' > /home/ci/gpgkey
    rm /tmp/sign.key

    msg3 "Setting makepkg.conf env variables"
    cat >> /etc/makepkg.conf << EOF
PACKAGER=\"${PACKAGER}\"
PKGDEST=/home/ci/pkgdest
LOGDEST=/home/ci/pkgdest
BUILDDIR=/home/ci/build
SRCDEST=/home/ci/srcdest
SRCPKGDEST=/home/ci/srcpkgdest
MAKEFLAGS=\"-j$(nproc)\"
CARCH=x86_64
BUILDTOOL=build.sh
BUILDTOOLVER=0.1
BUILDENV=(!distcc !color !ccache check sign)
GPGKEY=$(cat /home/ci/gpgkey)
EOF

    msg3 "Setting git"
    git config --global --add safe.directory /build
    git config --global --add safe.directory /home/ci/aurdir
}

finish() {
    msg2 "Copying package and logs to output directory"
    mv /home/ci/pkgdest/* /output
}

build() {
    local pkgdir="$1"

    msg2 "Build start"

    pushd "$pkgdir" > /dev/null || exit

    if [ -z ${SOURCE_DATE_EPOCH+x} ]; then
        local SOURCE_DATE_EPOCH
        SOURCE_DATE_EPOCH="$(git log -1 --format=%ct .)"
    fi

    local LC_ALL=C

    if ! sudo -u ci --preserve-env=SOURCE_DATE_EPOCH,LC_ALL makepkg -s --noprogressbar --noconfirm -L >/dev/null 2>/dev/null; then
        error "Build failed"
        finish
        exit 1
    fi

    finish

    popd >/dev/null || exit
}

package() {
    msg "Building custom package ${PKGNAME}"

    prepare
    build "/pkgdir"
}

aur() {
    local pkgname="$1"

    msg "Building AUR package ${PKGNAME}"
    prepare

    msg2 "Cloning AUR repository for package ${PKGNAME}"
    if ! sudo -u ci git clone -q -- "https://aur.archlinux.org/${pkgname}.git" /home/ci/aurdir; then
        error "Unable to clone AUR git repository"
        exit 1
    fi

    build "/home/ci/aurdir"
}

run_docker() {
    local cmd="$1"
    shift
    local docker_args=("$@")

    # ulimit: https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg1892339.html
    set -x
    pwd
    ls -la
    docker run --rm \
        --ulimit nofile=1024:524288 \
        -v "$(pwd)":/app:ro \
        -v "$(pwd)"/output:/output \
        -v "$(pwd)"/cache:/pacmanCache \
        --env-file=.env \
        ${docker_args[@]} \
        archlinux \
        bash -c "ls -la /app && /app/build.sh ${cmd}"
    set +x
}

repo_prepare() {
    msg "Creating repo '${REPONAME}' from packages in output directory"
    prepare

    pushd /output >/dev/null || exit
    msg2 "Running repo-add"
    if ! sudo -u ci repo-add --nocolor --sign --key "$(cat /home/ci/gpgkey)" "${REPONAME}.db.tar.xz" ./*.pkg.tar.zst >/dev/null; then
        error "Creating repository failed with return code $?"
        exit 1
    fi
    popd >/dev/null || exit
}

repo_publish() {
    msg "Publishing repo '${REPONAME}'"

    prepare
    installed_or_exit "rsync"

    msg2 "Setting up SSH client"
    mkdir -p /root/.ssh
    echo "${SSH_KNOWN_HOSTS}" > /root/.ssh/known_hosts
    echo "${SSH_PRIVATE_KEY}" | sed 's@\\n@\n@g' > /root/.ssh/id_ed25519
    chmod 400 /root/.ssh/id_ed25519

    msg2 "Copying repository using rsync"
    if ! rsync -rlptO /output/ "${SSH_REMOTE}:${SSH_REMOTE_DEST}/archlinux/${REPONAME}/x86_64"; then
        error "rsync failed with return code $?"
        rm /root/.ssh/id_ed25519
        exit 1
    fi

    rm /root/.ssh/id_ed25519
}

main() {
    installed_or_exit "docker"

    # rm -fr output/
    mkdir -p output/
    mkdir -p cache/

    msg "Pulling docker image"
    docker pull -q archlinux

    find packages -mindepth 1 -maxdepth 1 -type d -print0 | while IFS= read -r -d '' pkgdir
    do
        local pkgname
        pkgname="$(basename "${pkgdir}")"
        run_docker "package" \
            "-v $(pwd)/packages/${pkgname}:/pkgdir:ro" \
            "-e PKGNAME=${pkgname}" \
            "-e SOURCE_DATE_EPOCH=$(git log -1 --format=%ct "packages/${pkgname}")"
    done

    while read -r pkgname; do
        run_docker "aur ${pkgname}" "-e PKGNAME=${pkgname}"
    done < packages/aur.txt

    run_docker "repo-prepare"
    run_docker "repo-publish"
}

if [[ "$#" == 0 ]]; then
    main
elif [[ "$#" == 1 ]]; then
    case "$1" in
        package) package ;;
        repo-prepare) repo_prepare ;;
        repo-publish) repo_publish ;;
        *) echo "Invalid option"; exit 1 ;;
    esac
elif [[ "$#" == 2 && "$1" == "aur" ]]; then
    aur "$2"
fi

exit 0
