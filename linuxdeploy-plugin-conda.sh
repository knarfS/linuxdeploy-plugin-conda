#! /bin/bash

# abort on all errors
set -e

if [ "$DEBUG" != "" ]; then
    set -x
fi

script=$(readlink -f "$0")

CONDA_SKIP_ADJUST_PATHS=${CONDA_SKIP_ADJUST_PATHS:-"1"}
ARCH="${ARCH:-"$(uname -m)"}"

show_usage() {
    echo "Usage: $script --appdir <path to AppDir>"
    echo
    echo "Bundles software available as conda packages into an AppDir"
    echo
    echo "Variables:"
    echo "  CONDA_CHANNELS=\"channelA;channelB;...\""
    echo "  CONDA_PACKAGES=\"packageA;packageB;...\""
    echo "  CONDA_PYTHON_VERSION=\"3.6\""
    echo "  PIP_REQUIREMENTS=\"packageA packageB -r requirements.txt -e git+https://...\""
    echo "  PIP_PREFIX=\"AppDir/usr/share/conda\""
    echo "  ARCH=\"$ARCH\" (supported values: x86_64, i368, i686)"
    echo "  CONDA_SKIP_ADJUST_PATHS=\"1\" (default: skip)"
    echo "  CONDA_SKIP_CLEANUP=\"[all;][conda-pkgs;][__pycache__;][strip;][.a;][cmake;][doc;][man;][site-packages;]\""
}

_isterm() {
    tty -s && [[ "$TERM" != "" ]] && tput colors &>/dev/null
}

log() {
    _isterm && tput setaf 3
    _isterm && tput bold
    echo -*- "$@"
    _isterm && tput sgr0
    return 0
}

APPDIR=

while [ "$1" != "" ]; do
    case "$1" in
        --plugin-api-version)
            echo "0"
            exit 0
            ;;
        --appdir)
            APPDIR="$2"
            shift
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            log "Invalid argument: $1"
            log
            show_usage
            exit 1
            ;;
    esac
done

if [ "$APPDIR" == "" ]; then
    show_usage
    exit 1
fi

mkdir -p "$APPDIR"

if [ "$CONDA_PACKAGES" == "" ]; then
    log "WARNING: \$CONDA_PACKAGES not set, no packages will be installed!"
fi

# the user can specify a directory into which the conda installer is downloaded
# if they don't specify one, we use a temporary directory with a predictable name to preserve downloaded files across runs
# this should reduce the download overhead
# if one is specified, the installer will not be re-downloaded unless it has changed
if [ "$CONDA_DOWNLOAD_DIR" != "" ]; then
    # resolve path relative to cwd
    if [[ "$CONDA_DOWNLOAD_DIR" != /* ]]; then
        CONDA_DOWNLOAD_DIR="$(readlink -f "$CONDA_DOWNLOAD_DIR")"
    fi

    log "Using user-specified download directory: $CONDA_DOWNLOAD_DIR"
else
    # create temporary directory into which downloaded files are put
    CONDA_DOWNLOAD_DIR="/tmp/linuxdeploy-plugin-conda-$(id -u)"

    log "Using default temporary download directory: $CONDA_DOWNLOAD_DIR"
fi

# make sure the directory exists
mkdir -p "$CONDA_DOWNLOAD_DIR"

if [ -d "$APPDIR"/usr/conda ]; then
    log "WARNING: conda prefix directory exists: $APPDIR/usr/conda"
    log "Please make sure you perform a clean build before releases to make sure your process works properly."
fi

# install Miniconda, a self contained Python distribution, into AppDir
case "$ARCH" in
    "x86_64")
        miniconda_installer_filename=Miniconda3-latest-Linux-x86_64.sh
        ;;
    "i386"|"i686")
        miniconda_installer_filename=Miniconda3-latest-Linux-x86.sh
        ;;
    *)
        log "ERROR: Unknown Miniconda arch: $ARCH"
        exit 1
        ;;
esac

pushd "$CONDA_DOWNLOAD_DIR"
    miniconda_url=https://repo.anaconda.com/miniconda/"$miniconda_installer_filename"
    # let's make sure the file exists before we then rudimentarily ensure mutual exclusive access to it with flock
    # we set the timestamp to epoch 0; this should likely trigger a redownload for the first time
    touch "$miniconda_installer_filename" -d '@0'

    # now, let's download the file
    flock "$miniconda_installer_filename" wget -N -c "$miniconda_url"
popd

# install into usr/conda/ instead of usr/ to make sure that the libraries shipped with conda don't overwrite or
# interfere with libraries bundled by other plugins or linuxdeploy itself
bash "$CONDA_DOWNLOAD_DIR"/"$miniconda_installer_filename" -b -p "$APPDIR"/usr/conda -f

# activate environment
. "$APPDIR"/usr/conda/bin/activate

# we don't want to touch the system, therefore using a temporary home
mkdir -p _temp_home
export HOME=$(readlink -f _temp_home)

# conda-forge is used by many conda packages, therefore we'll add that channel by default
conda config --add channels conda-forge

# force-install libxi, required by a majority of packages on some more annoying distributions like e.g., Arch
#conda install -y xorg-libxi

# force another python version if requested
if [ "$CONDA_PYTHON_VERSION" != "" ]; then
    conda install -y python="$CONDA_PYTHON_VERSION"
fi

# add channels specified via $CONDA_CHANNELS
IFS=';' read -ra chans <<< "$CONDA_CHANNELS"
for chan in "${chans[@]}"; do
    conda config --append channels "$chan"
done

# install packages specified via $CONDA_PACKAGES
IFS=';' read -ra pkgs <<< "$CONDA_PACKAGES"
for pkg in "${pkgs[@]}"; do
    conda install -y "$pkg"
done

# make sure pip is up to date
pip install -U pip

# install requirements from PyPI specified via $PIP_REQUIREMENTS
if [ "$PIP_REQUIREMENTS" != "" ]; then
    if [ "$PIP_WORKDIR" != "" ]; then
        pushd "$PIP_WORKDIR"
    fi

    pip install -U $PIP_REQUIREMENTS ${PIP_PREFIX:+--prefix=$PIP_PREFIX} ${PIP_VERBOSE:+-v}

    if [ "$PIP_WORKDIR" != "" ]; then
        popd
    fi
fi

# create symlinks for all binaries in usr/conda/bin/ in usr/bin/
mkdir -p "$APPDIR"/usr/bin/
pushd "$APPDIR"
for i in usr/conda/bin/*; do
    if [ -f usr/bin/"$(basename "$i")" ]; then
        log "WARNING: symlink exists, will not be touched: usr/bin/$i"
    else
        ln -s ../../"$i" usr/bin/
    fi
done
popd

# adjust absolute paths, by default skipped via $CONDA_SKIP_ADJUST_PATHS
if [ "$CONDA_SKIP_ADJUST_PATHS" != "1" ]; then
    # disable history substitution, b/c we use ! in quoted strings
    set +H
    APPDIR_FULL="$(pwd)/$APPDIR"
    pushd "$APPDIR_FULL"
    # NOTE: --follow-symlinks is only working for GNU sed
    # replace absolute paths in some specific files (regex could result in false replacements in other files)
    [ -f usr/conda/etc/profile.d/conda.sh ] && sed -i --follow-symlinks "s|'$APPDIR_FULL|\"\${APPDIR}\"'|g" usr/conda/etc/profile.d/conda.sh
    [ -f usr/conda/etc/profile.d/conda.sh ] && sed -i --follow-symlinks "s|$APPDIR_FULL|\${APPDIR}|g" usr/conda/etc/profile.d/conda.sh
    [ -f usr/conda/etc/profile.d/conda.csh ] && sed -i --follow-symlinks "s|$APPDIR_FULL|\${APPDIR}|g" usr/conda/etc/profile.d/conda.csh
    [ -f usr/conda/etc/fish/conf.d/conda.fish ] && sed -i --follow-symlinks "s|$APPDIR_FULL|\$APPDIR|g" usr/conda/etc/fish/conf.d/conda.fish
    # generic files in usr/conda/bin/ and usr/conda/condabin/
    for i in usr/conda/bin/* usr/conda/condabin/*; do
        [ -f "$i" ] || continue
        # shebangs
        sed -i --follow-symlinks "s|^#!$APPDIR_FULL/usr/conda/bin/|#!/usr/bin/env |" "$i"
        # perl assignments (must be before bash assignments)
        sed -ri --follow-symlinks "s|^(my.*=[[:space:]]*\")$APPDIR_FULL|\1\$ENV{APPDIR} . \"|g" "$i"
        # bash assignments
        sed -ri --follow-symlinks "s|(=[[:space:]]*\")$APPDIR_FULL|\1\${APPDIR}|g" "$i"
    done
    # specific files in usr/conda/bin/ (regex could result in false replacements in other files)
    [ -f usr/conda/bin/python3-config ] && sed -i --follow-symlinks "s|$APPDIR_FULL|\${APPDIR}|g" usr/conda/bin/python3-config
    [ -f usr/conda/bin/ncursesw6-config ] && sed -i --follow-symlinks "s|$APPDIR_FULL|\${APPDIR}|g" usr/conda/bin/ncursesw6-config
    popd

    # generate linuxdeploy-plugin-conda-hook
    mkdir -p "$APPDIR"/apprun-hooks
    cat > "$APPDIR"/apprun-hooks/linuxdeploy-plugin-conda-hook.sh <<\EOF
# generated by linuxdeploy-plugin-conda

# export APPDIR variable to allow for running from extracted AppDir as well
export APPDIR="${APPDIR:-$(readlink -f "$(dirname "$0")")}"
# export PATH to allow /usr/bin/env shebangs to use the supplied applications
export PATH="$APPDIR"/usr/bin:"$PATH"
EOF

fi

# remove bloat, optionally skipped via $CONDA_SKIP_CLEANUP
IFS=';' read -ra cleanup <<< "$CONDA_SKIP_CLEANUP"
for skip in "${cleanup[@]}"; do
    lskip="$(tr '[:upper:]' '[:lower:]' <<< "$skip")"
    case "$lskip" in
        "all"| \
        "1"|"true"|"y"|"yes")  # To allow SOME backward compatibility - versions previous
                               # to this comment allowed any value of $CONDA_SKIP_CLEANUP.
            skip_cleanup=1
            ;;
        "conda-pkgs")
            skip_conda_pkgs_cleanup=1
            ;;
        "__pycache__")
            skip_pycache_cleanup=1
            ;;
        "strip")
            skip_strip_cleanup=1
            ;;
        ".a")
            skip_a_cleanup=1
            ;;
        "cmake")
            skip_cmake_cleanup=1
            ;;
        "doc")
            skip_doc_cleanup=1
            ;;
        "man")
            skip_man_cleanup=1
            ;;
        "site-packages")
            skip_site_packages_cleanup=1
            ;;
        *)
            log "ERROR: Unknown CONDA_SKIP_CLEANUP value: $skip"
            log
            show_usage
            exit 1
            ;;
    esac
done

if [ "$skip_cleanup" != "1" ]; then
    pushd "$APPDIR"/usr/conda
    (($skip_conda_pkgs_cleanup)) || rm -rf pkgs
    (($skip_pycache_cleanup)) || find -type d -iname '__pycache__' -print0 | xargs -0 rm -r
    (($skip_strip_cleanup)) || find -type f -iname '*.so*' -print -exec strip '{}' \;
    (($skip_a_cleanup)) || find -type f -iname '*.a' -print -delete
    (($skip_cmake_cleanup)) || rm -rf lib/cmake/
    (($skip_doc_cleanup)) || rm -rf share/{gtk-,}doc
    (($skip_man_cleanup)) || rm -rf share/man
    (($skip_site_packages_cleanup)) || rm -rf lib/python?.?/site-packages/{setuptools,pip}
    popd
fi

