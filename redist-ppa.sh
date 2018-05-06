#!/bin/bash

# This shell script will create Ubuntu source packages which we can pass to
# launchpad.net (e.g.) to build.  The build environment, options, etc. are
# --- and _should be_! --- kept in sync with those in build.sh as far as
# possible.  There are a few important exceptions:
#
#   * The respective packaging scripts (ppa-pkging/*/rules, which become
#     debian/rules) arrange to install .info files in their own directory
#     (/usr/ia16-elf/info/) rather than the expected place ($PREFIX/share/
#     info/).  This is to avoid clashing with any .info files for the host
#     system's binutils, GCC, etc.
#
#   * The trimmed-down stage 1 and 2 GCC source trees need some help to
#     correctly set up gcc/include-fixed/limits.h .
#
# There is a Personal Package Archive (PPA) for the source packages I have
# created, at https://launchpad.net/~tkchia/+archive/ubuntu/build-ia16/ .
#
# For Ubuntu Trusty, the mainline version of libisl (0.12-2) is too old, so
# I have copied over the libisl 0.16.1-1 from Jonathon F's PPA
# (https://launchpad.net/%7Ejonathonf/+archive/ubuntu/gcc-5.3/+packages)
# into my PPA.
#
# TODO: create more fine-grained packages, e.g. rather than one big package
# gcc-ia16-elf, have separate packages for the C compiler, C++ compiler,
# libgcc1, etc.

set -e -o pipefail
cd $(dirname "$0")

# (These are mostly lifted from build.sh ...)
in_list () {
  local needle=$1
  local haystackname=$2
  local -a haystack
  eval "haystack=( "\${$haystackname[@]}" )"
  for x in "${haystack[@]}"; do
    if [ "$x" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

distro=
while [ $# -gt 0 ]; do
  case "$1" in
    clean|binutils|gcc1|newlib|gcc2|stubs)
      BUILDLIST=( "${BUILDLIST[@]}" $1 )
      ;;
    all)
      BUILDLIST=("clean" "binutils" "gcc1" "newlib" "gcc2" "stubs")
      ;;
    --distro=?*)
      distro="${1#--distro=}"
      ;;
    *)
      echo "Unknown option '$1'."
      exit 1
      ;;
  esac
  shift
done

if [ "${#BUILDLIST}" -eq 0 ]; then
  echo "redist-ppa options:"
  echo "--distro={trusty|xenial|...} clean binutils gcc1 newlib gcc2 stubs"
  exit 1
fi

# Capture the current date and time, and fabricate a package revision number
# from an abbreviated version of the current date and time.  Use UTC all the
# way, for great consistency.
export TZ=UTC0
curr_tm="`date -R`"
ppa_no="`date -d "$curr_tm" +%y%m%d%H%M`"
ppa_no="${ppa_no%?}"

# If no target Ubuntu distribution is specified, obtain the code name for
# whatever Linux distribution we are running on, or fall back on a wild
# guess.
if [ -z "$distro" ]; then
  distro="`sed -n '/^DISTRIB_CODENAME=[[:alnum:]]\+$/ { s/^.*=//; p; q; }' \
    /etc/lsb-release || :`"
  if [ -z "$distro" ]
    then distro=xenial; fi
fi

case "$distro" in
  '' | *[^-0-9a-z]*)
    echo "Bad distribution name (\`$distro')!"
    exit 1
    ;;
esac

if in_list clean BUILDLIST; then
  echo
  echo "************"
  echo "* Cleaning *"
  echo "************"
  echo
  # Create and clean up our working directory.
  rm -rf redist-ppa
  mkdir redist-ppa
fi

. redist-common.sh

if in_list binutils BUILDLIST; then
  echo
  echo "**********************"
  echo "* Packaging binutils *"
  echo "**********************"
  echo
  # Package up binutils-ia16 as a source package.
  rm -rf redist-ppa/"$distro"/binutils-ia16-elf_*
  decide_binutils_ver_and_dirs
  mkdir -p redist-ppa/"$distro"/"$bu_pdir"
  # Copy the source tree over, but do not include .git* or untracked files.
  (cd binutils-ia16 && git archive --prefix="$bu_dir"/ HEAD) | xz -9v \
    >redist-ppa/"$distro"/"$bu_dir".orig.tar.xz
  pushd redist-ppa/"$distro"/"$bu_pdir"
  # We do not really need to do this unpacking here:
  #	tar xJf ../"$bu_dir".orig.tar.xz --strip-components=1
  # ...but we do need to tell debuild later to ignore all the "removed" files
  # in the source tree.
  dh_make -s -p "$bu_pdir" -n -f ../"$bu_dir".orig.tar.xz -y
  rm debian/*.ex debian/*.EX debian/README debian/README.*
  cp -a ../../../ppa-pkging/build-binutils/* debian/
  find debian -name '*~' -print0 | xargs -0 rm -f
  # TODO:
  #   * Generate the most recent changelog entry in a saner way.  E.g. 
  #     extract and include the user id information from $DEBSIGN_KEYID.
  #   * Include changelog entries for actual source changes.
  (
    echo "binutils-ia16-elf ($bu_pver) $distro; urgency=low"
    echo
    echo '  * Release.'
    echo
    echo " -- user <user@localhost.localdomain>  $curr_tm"
  ) >debian/changelog
  cp -a debian/docs debian/*.docs
  # (1) Since we do not unpack the .orig tarball at all, we need to tell
  #	debuild to ignore all the file "removals" in the "unpacked" source
  #	tree.
  #
  # (2) The dpkg-buildpackage(1) and debsign(1) man pages claim to recognize
  #	the $DEB_SIGN_KEYID and $DEBSIGN_KEYID environment variables
  #	respectively.  In practice though, debuild(1) actually just uses
  #	whatever name and e-mail address is in the changelog to serve as the
  #	key id.  So work around this.
  debuild -i'.*' -S ${DEBSIGN_KEYID+"-k$DEBSIGN_KEYID"}
  popd
fi

if in_list gcc1 BUILDLIST; then
  echo
  echo "*************************"
  echo "* Packaging stage 1 GCC *"
  echo "*************************"
  echo
  # Package up gcc-ia16 as a source package.  My current idea is that this
  # `gcc-bootstraps-ia16-elf' package will only be used to build newlib, and
  # then it can be safely jettisoned.  So I try to pack as little stuff as
  # possible into the `.orig' tarball.
  #
  # (The resulting tarball is still pretty big though (20+ MiB).  There is
  # likely a better way...)
  rm -rf redist-ppa/"$distro"/gcc-bootstraps-ia16-elf_*
  decide_binutils_ver_and_dirs
  decide_gcc_ver_and_dirs
  mkdir -p redist-ppa/"$distro"/"$g1_pdir"
  # Copy the source tree over, but do not include .git* or untracked files.
  #
  # Also exclude the _huge_ testsuite, and language support other than for C
  # and C++.  (C++ is needed for gcc/c-family/cilk.c to build...)  This is a
  # bit hard to do with `git archive' alone --- without dirtying the
  # original source tree --- so rope in GNU tar for the task.
  #
  # Also take out the boehm-gc/ and libffi/ directories, which we do not
  # really need at this stage.  Keep gcc/fortran/, gcc/go/, and gcc/java/
  # around so that libbacktrace/ will not be built for ia16-elf (!).
  (cd gcc-ia16 && \
   git archive --prefix="$g1_dir"/ HEAD | \
   tar --delete --wildcards \
    "$g1_dir"/gotools "$g1_dir"/libada "$g1_dir"/libgfortran "$g1_dir"/libgo \
    "$g1_dir"/libjava "$g1_dir"/libobjc "$g1_dir"/libsanitizer \
    "$g1_dir"/libstdc++-v3 "$g1_dir"/gcc/testsuite "$g1_dir"/gcc/ada \
    "$g1_dir"/gnattools "$g1_dir"/gcc/objc "$g1_dir"/boehm-gc \
    "$g1_dir"/libffi "$g1_dir/gcc/ChangeLog*") | \
    xz -9v \
    >redist-ppa/"$distro"/"$g1_dir".orig.tar.xz
  pushd redist-ppa/"$distro"/"$g1_pdir"
  dh_make -s -p "$g1_pdir" -n -f ../"$g1_dir".orig.tar.xz -y
  rm debian/*.ex debian/*.EX debian/README debian/README.*
  cp -a ../../../ppa-pkging/build/* debian/
  sed "s|@bu_ver@|$bu_ver|g" debian/control.in >debian/control
  rm debian/control.in
  find debian -name '*~' -print0 | xargs -0 rm -f
  (
    echo "gcc-bootstraps-ia16-elf ($gcc_pver) $distro; urgency=low"
    echo
    echo '  * Release.'
    echo
    echo " -- user <user@localhost.localdomain>  $curr_tm"
  ) >debian/changelog
  cp -a debian/docs debian/*.docs
  debuild -i'.*' -S ${DEBSIGN_KEYID+"-k$DEBSIGN_KEYID"}
  cd ..
  popd
fi

if in_list newlib BUILDLIST; then
  echo
  echo "******************************"
  echo "* Packaging Newlib C library *"
  echo "******************************"
  echo
  rm -rf redist-ppa/"$distro"/libnewlib-ia16-elf_*
  decide_binutils_ver_and_dirs
  decide_gcc_ver_and_dirs
  decide_newlib_ver_and_dirs
  mkdir -p redist-ppa/"$distro"/"$nl_pdir"
  (cd newlib-ia16 && git archive --prefix="$nl_dir"/ HEAD) | xz -9v \
    >redist-ppa/"$distro"/"$nl_dir".orig.tar.xz
  pushd redist-ppa/"$distro"/"$nl_pdir"
  dh_make -s -p "$nl_pdir" -n -f ../"$nl_dir".orig.tar.xz -y
  rm debian/*.ex debian/*.EX debian/README debian/README.*
  cp -a ../../../ppa-pkging/build-newlib/* debian/
  sed -e "s|@bu_ver@|$bu_ver|g" -e "s|@gcc_ver@|$gcc_ver|g" \
    debian/control.in >debian/control
  rm debian/control.in
  find debian -name '*~' -print0 | xargs -0 rm -f
  (
    echo "libnewlib-ia16-elf ($nl_pver) $distro; urgency=low"
    echo
    echo '  * Release.'
    echo
    echo " -- user <user@localhost.localdomain>  $curr_tm"
  ) >debian/changelog
  cp -a debian/docs debian/*.docs
  debuild -i'.*' -S ${DEBSIGN_KEYID+"-k$DEBSIGN_KEYID"}
  popd
fi

if in_list gcc2 BUILDLIST; then
  echo
  echo "*************************"
  echo "* Packaging stage 2 GCC *"
  echo "*************************"
  echo
  rm -rf redist-ppa/"$distro"/gcc-ia16-elf_*
  decide_binutils_ver_and_dirs
  decide_gcc_ver_and_dirs
  decide_newlib_ver_and_dirs
  mkdir -p redist-ppa/"$distro"/"$g2_pdir"
  # Copy the source tree over, except for .git* files, untracked files, and
  # the bigger testsuites.
  (cd gcc-ia16 && \
   git archive --prefix="$g2_dir"/ HEAD | \
   tar --delete --wildcards "$g2_dir"/libjava/testsuite \
    "$g2_dir"/gcc/testsuite "$g2_dir"/libgomp/testsuite) | \
    xz -9v \
    >redist-ppa/"$distro"/"$g2_dir".orig.tar.xz
  pushd redist-ppa/"$distro"/"$g2_pdir"
  dh_make -s -p "$g2_pdir" -n -f ../"$g2_dir".orig.tar.xz -y
  rm debian/*.ex debian/*.EX debian/README debian/README.*
  cp -a ../../../ppa-pkging/build2/* debian/
  sed -e "s|@bu_ver@|$bu_ver|g" -e "s|@nl_ver@|$nl_ver|g" debian/control.in \
    >debian/control
  rm debian/control.in
  find debian -name '*~' -print0 | xargs -0 rm -f
  (
    echo "gcc-ia16-elf ($g2_pver) $distro; urgency=low"
    echo
    echo '  * Release.'
    echo
    echo " -- user <user@localhost.localdomain>  $curr_tm"
  ) >debian/changelog
  cp -a debian/docs debian/*.docs
  debuild -i'.*' -S ${DEBSIGN_KEYID+"-k$DEBSIGN_KEYID"}
  cd ..
  popd
fi

if in_list stubs BUILDLIST; then
  echo
  echo "**************************"
  echo "* Creating stub packages *"
  echo "**************************"
  echo
  rm -rf redist-ppa/"$distro"/gcc-stubs-ia16-elf_*
  decide_gcc_ver_and_dirs
  mkdir -p redist-ppa/"$distro"/"$gs_pdir"
  pushd redist-ppa/"$distro"/"$gs_pdir"
  dh_make -s -p "$gs_pdir" -n -y
  rm debian/*.ex debian/*.EX debian/README debian/README.*
  cp -a ../../../ppa-pkging/build-stubs-gcc/* debian/
  sed "s|@gcc_ver@|$gcc_ver|g" debian/control.in >debian/control
  rm debian/control.in
  find debian -name '*~' -print0 | xargs -0 rm -f
  (
    echo "gcc-stubs-ia16-elf ($gcc_pver) $distro; urgency=low"
    echo
    echo '  * Release.'
    echo
    echo " -- user <user@localhost.localdomain>  $curr_tm"
  ) >debian/changelog
  cp -a debian/docs debian/*.docs
  debuild --no-tgz-check -i -S ${DEBSIGN_KEYID+"-k$DEBSIGN_KEYID"}
  cd ..
  popd
fi
