#!/bin/bash

__dir__="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=scripts/configuration.sh
source "$__dir__/configuration.sh"
# shellcheck source=scripts/digest.sh
source "$__dir__/digest.sh"
# shellcheck source=scripts/github.sh
source "$__dir__/github.sh"
# shellcheck source=scripts/aws.sh
source "$__dir__/aws.sh"
# shellcheck source=scripts/io.sh
source "$__dir__/io.sh"

function rbx_release_bucket {
  echo "rubinius-releases-rubinius-com"
}

function rbx_binary_bucket {
  echo "rubinius-binaries-rubinius-com"
}

function rbx_url_prefix {
  local bucket=$1
  echo "https://${bucket}.s3-us-west-2.amazonaws.com"
}

function rbx_upload_files {
  local bucket dest src path url name index
  local -a file_exts

  bucket=$1
  dest=$2
  src=$3
  path=${4:-}
  url=$(rbx_url_prefix "$bucket")
  file_exts=("" ".sha512")
  index="index.txt"

  rbx_s3_download "$url" "$index"

  # Upload all the files first.
  for ext in "${file_exts[@]}"; do
    if [[ -f $src$ext ]]; then
      rbx_s3_upload "$url" "$bucket" "$dest$ext" "$src$ext" "$path" ||
        fail "unable to upload file"
    fi
  done

  # Update the index and upload it.
  for ext in "${file_exts[@]}"; do
    if [[ -n $path ]]; then
      name="$url$path$dest$ext"
    else
      name="$dest$ext"
    fi

    grep "^$name\$" "$index"
    if [ $? -ne 0 ]; then
      echo "$name" >> "$index"
    fi
  done

  rbx_s3_upload "$url" "$bucket" "$index" "$index" || fail "unable to upload index"
}

# Build and upload the release tarball to S3.
function rbx_deploy_release_tarball {
  if [[ $1 == osx ]]; then
    echo "Deploying release tarball $(rbx_release_name)..."

    "$__dir__/release.sh" || fail "unable to build release tarball"

    rbx_upload_files "$(rbx_release_bucket)" "$(rbx_release_name)" "$(rbx_release_name)"
  fi
}

# Build and upload a Homebrew binary to S3.
function rbx_deploy_homebrew_binary {
  if [[ $1 == osx ]]; then
    echo "Deploying Homebrew binary $(rbx_release_name)..."

    "$__dir__/package.sh" homebrew || fail "unable to build Homebrew binary"

    rbx_upload_files "$(rbx_binary_bucket)" "$(rbx_release_name)" \
      "$(rbx_release_name)" "/homebrew/"

    rbx_deploy_homebrew_release
  fi
}

# Build and upload a binary to S3.
function rbx_deploy_travis_binary {
  local os_name vendor_llvm

  os_name=$1
  echo "Deploying Travis binary $(rbx_release_name) for $os_name..."

  # TODO: Remove this hack when LLVM 3.6/7 support lands.
  if [[ $os_name == linux ]]; then
    vendor_llvm="./vendor/llvm/Release/bin/llvm-config"
    if [[ -f "$vendor_llvm" ]]; then
      export RBX_BINARY_CONFIG="--llvm-config=$vendor_llvm"
    fi
  fi

  "$__dir__/package.sh" binary || fail "unable to build binary"

  declare -a paths os_releases versions

  if [[ $os_name == linux ]]; then
    os_releases=("12.04" "14.04" "15.10")
    for (( i=0; i < ${#os_releases[@]}; i++ )); do
      paths[i]="/ubuntu/${os_releases[i]}/x86_64/"
    done
  elif [[ $os_name == osx ]]; then
    os_releases=("10.9" "10.10" "10.11")
    for (( i=0; i < ${#os_releases[@]}; i++ )); do
      paths[i]="/osx/${os_releases[i]}/x86_64/"
    done
  else
    echo "${FUNCNAME[1]}: no match for OS name"
    return
  fi

  IFS="." read -r -a array <<< "$(rbx_revision_version)"

  let i=0
  version=""
  versions[i]=""

  for v in "${array[@]}"; do
    let i=i+1
    versions[i]="-$version$v"
    version="$v."
  done

  for path in "${paths[@]}"; do
    for version in "${versions[@]}"; do
      rbx_upload_files "$(rbx_binary_bucket)" "rubinius$version.tar.bz2" \
        "$(rbx_release_name)" "$path"
    done
  done
}

function rbx_deploy_github_release {
  local os_name upload_url

  os_name=$1

  if [[ $os_name == osx ]]; then
    upload_url=$(rbx_github_release "$(rbx_revision_version)" "$(rbx_revision_date)")

    rbx_github_release_assets "$upload_url" "$(rbx_release_name)"
  fi
}

function rbx_deploy_website_release {
  local os_name releases updates version url response sha download_url

  os_name=$1

  if [[ $os_name == osx ]]; then
    releases="releases.yml"
    updates="updated_$releases"
    version=$(rbx_revision_version)
    url="https://api.github.com/repos/rubinius/rubinius.github.io/contents/_data/releases.yml"

    response=$(curl "$url")

    download_url=$(echo "$response" | "$__dir__/json.sh" -b | \
      egrep '\["download_url"\][[:space:]]\"[^"]+\"' | egrep -o '\"[^\"]+\"$')
    curl -o "$releases" "${download_url:1:${#download_url}-2}"

    grep "^- version: \"$version\"\$" "$releases"
    if [ $? -eq 0 ]; then
      return
    fi

    sha=$(echo "$response" | "$__dir__/json.sh" -b | \
      egrep '\["sha"\][[:space:]]\"[^"]+\"' | egrep -o '\"[[:xdigit:]]+\"')

    cat > "$updates" <<EOF
- version: "$version"
  date: $(rbx_revision_date)
EOF

    cat "$releases" >> "$updates"

    rbx_github_update_file "$updates" "${sha:1:${#sha}-2}" "Version $version." "$url"
  fi
}

function rbx_deploy_homebrew_release {
  local release file url response sha

  release=$(rbx_release_name)
  file="rubinius.rb"
  url="https://api.github.com/repos/rubinius/homebrew-apps/contents/$file"
  response=$(curl $url)

  cat > "$file" <<EOF
require 'formula'

class Rubinius < Formula
  homepage 'http://rubinius.com/'
  url 'https://rubinius-binaries-rubinius-com.s3.amazonaws.com/homebrew/$release'
  sha1 '$(cat "$release.sha1")'

  depends_on 'libyaml'

  depends_on :arch => :x86_64
  depends_on MinimumMacOSRequirement => :mountain_lion

  keg_only "Conflicts with MRI (Matz's Ruby Implementation)."

  def install
    bin.install Dir["bin/*"]
    lib.install Dir["lib/*"]
    include.install Dir["include/*"]
    man1.install Dir["man/man1/*"]
  end

  test do
    assert_equal 'rbx', \`"#{bin}/rbx" -e "puts RUBY_ENGINE"\`.chomp
  end
end
EOF

  sha=$(echo "$response" | "$__dir__/json.sh" -b | \
    egrep '\["sha"\][[:space:]]\"[^"]+\"' | egrep -o '\"[[:xdigit:]]+\"')

  let i=${#sha}

  rbx_github_update_file "$file" "${sha:1:$i-2}" "Version $(rbx_revision_version)" "$url"

  rm "$file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -z $1 ]]; then
    "$0" release github travis homebrew website
    exit $?
  fi

  for cmd in "${@}"; do
    case "$cmd" in
      "release")
        rbx_deploy_release_tarball "$TRAVIS_OS_NAME"
        ;;
      "github")
        rbx_deploy_github_release "$TRAVIS_OS_NAME"
        ;;
      "travis")
        rbx_deploy_travis_binary "$TRAVIS_OS_NAME"
        ;;
      "homebrew")
        rbx_deploy_homebrew_binary "$TRAVIS_OS_NAME"
        ;;
      "website")
        rbx_deploy_website_release "$TRAVIS_OS_NAME"
        ;;
      *)
        cat >&2 <<-EOM
Usage: ${0##*/} [release github travis homebrew website]

If no arguments are passed, all deploy tasks are run.
EOM
        exit 1
        ;;
    esac
  done
fi
