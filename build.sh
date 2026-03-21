#!/bin/bash

setup() {
  MACHINE_ARCH=$(gcc -dumpmachine|cut -d- -f1)
  case $MACHINE_ARCH in
    x86_64)
      CPU_ARCH=x86_64
      ;;
    aarch64)
      CPU_ARCH=$(gcc -march=native -Q --help=target -v 2> /dev/null|grep -- "^  -march"|tr -d ' \t'|cut -d= -f2|cut -d+ -f1)
      ;;
    arm)
      CPU_ARCH=$(gcc -march=native -Q --help=target -v 2> /dev/null|grep -- "^  -march"|tr -d ' \t'|cut -d= -f2|cut -d+ -f1)
      ;;
  esac
  export MACHINE_ARCH
  export CPU_ARCH

  mkdir -p "$WORK_DIR"/build
  mkdir -p "$WORK_DIR"/download
  mkdir -p "$TARGET_DIR"
  mkdir -p "$PREFIX_DIR"
  mkdir -p "$LV2_DIR"
}

parse() {
  NAME=$(yq eval '.plugin.name' "$1")
  VERSION=$(yq eval '.plugin.version' "$1")
  SOURCE_TYPE=$(yq eval '.plugin.source.type' "$1")
  BUILD_COMMANDS=$(yq ".plugin.build" "$1"| sed "s/^- //")
  INSTALL_COMMANDS=$(yq ".plugin.install" "$1"| sed "s/^- //")
  DATA_TYPE=$(yq eval '.plugin.data.type' "$1")
  BUNDLES=$(yq eval '.plugin.bundles[]' "$1" 2>/dev/null)
  DEPENDENCIES=$(yq eval '.plugin.dependencies[]' "$1" 2>/dev/null)
  PLUGIN_DIR=$(pwd)/$(dirname "$1")
  SOURCE_DIR="$WORK_DIR/build/$NAME-$VERSION"
}

check_dependencies() {
  if [ -z "$DEPENDENCIES" ]; then
    return 0
  fi
  MISSING=""
  for pkg in $DEPENDENCIES; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      MISSING="$MISSING $pkg"
    fi
  done
  if [ -n "$MISSING" ]; then
    echo "=== Missing dependencies for $NAME:$MISSING ==="
    read -r -p "Install them now? [Y/n] " answer
    case "$answer" in
      [nN]*)
        echo "Skipping $NAME (missing dependencies)"
        return 1
        ;;
      *)
        sudo apt-get install -y $MISSING || return 1
        ;;
    esac
  fi
  return 0
}

download() {
  echo "=== Download: $NAME ==="
  case $SOURCE_TYPE in
    http)
      URL=$(yq eval '.plugin.source.url' "$1")
      DOWNLOAD="$WORK_DIR/download/$NAME-$VERSION.tar.gz"
      if [ ! -f "$DOWNLOAD" ]; then
        wget -O "$DOWNLOAD" "$URL"
      fi
      pushd "$WORK_DIR/build" > /dev/null || exit
      tar xzf "$DOWNLOAD"
      cd "$NAME"* || exit
      popd || exit
      ;;
    git)
      if [ ! -d "$SOURCE_DIR" ]; then
        URL=$(yq eval '.plugin.source.url' "$1")
        pushd "$WORK_DIR/build" || exit
        git clone --branch "$VERSION" --depth 1 --recurse-submodules "$URL" "$NAME-$VERSION"
        popd > /dev/null || exit
      fi
      ;;
    *)
      echo "Unknown source type in $1"
      return
      ;;
  esac
}

prepare() {
  echo "=== Patch: $NAME ==="
  find "$PLUGIN_DIR" -name "*.patch" -type f -print -exec patch -d "$SOURCE_DIR" -N -p1 -i {} \;
  if [ -d "$PLUGIN_DIR/overlay" ]; then
     cp -rv "$PLUGIN_DIR"/overlay/* "$SOURCE_DIR"
  fi 
}

build() {
  pushd "$SOURCE_DIR" > /dev/null || exit
  while IFS= read -r line; do
      echo "Executing: $line"
      eval "$line" || exit
  done <<< "$BUILD_COMMANDS"
  popd > /dev/null  || exit
}

install() {
  echo "=== Install: $NAME ==="
  if [ -n "$BUNDLES" ]; then
    PLUGINS="$BUNDLES"
  else
    PLUGINS=$(find "$SOURCE_DIR" -type d -name "*.lv2" -exec basename {} \;| sort|uniq)
  fi
  echo "Bundles:"
  echo "$PLUGINS"
  pushd "$SOURCE_DIR" > /dev/null || exit
  while IFS= read -r line; do
      echo "Executing: ${line}"
      eval "$line" || exit
  done <<< "$INSTALL_COMMANDS"
  popd > /dev/null || exit

  case $DATA_TYPE in
    local)
      ;;
    null)
      for PLUGIN in $PLUGINS; do
        find "$DIR/data" -name "$PLUGIN" -type d -exec cp -rv {} "$LV2_DIR" \;
      done
      ;;
    *)
      find "$DIR/data" -name "$DATA_TYPE" -type d -exec cp -rv {} "$LV2_DIR" \;
      ;;
  esac
}

package() {
  echo "=== Package: $NAME ==="
  BUILD_DATE=$(date +%Y%m%d)
  PACKAGE_DIR="$WORK_DIR/packages"
  mkdir -p "$PACKAGE_DIR"
  for BUNDLE in $PLUGINS; do
    BUNDLE_PATH="$LV2_DIR/$BUNDLE"
    if [ ! -d "$BUNDLE_PATH" ]; then
      echo "Warning: bundle $BUNDLE not found at $BUNDLE_PATH, skipping"
      continue
    fi
    ARCHIVE_NAME="${BUNDLE%.lv2}-${VERSION}-${BUILD_DATE}-${MACHINE_ARCH}.tar.gz"
    tar -czf "$PACKAGE_DIR/$ARCHIVE_NAME" -C "$LV2_DIR" "$BUNDLE"
    echo "Packaged: $PACKAGE_DIR/$ARCHIVE_NAME"
  done
}

clean() {
  rm -rf "$SOURCE_DIR"
}

### Environment variables
DIR=$(dirname "$0")
RESOLVED_DIR=$(cd "$DIR" >/dev/null; pwd)
WORK_DIR=$RESOLVED_DIR/work
export TARGET_DIR="$WORK_DIR/target"
export PREFIX_DIR="$TARGET_DIR/usr"
export LV2_DIR="$PREFIX_DIR/lib/lv2"
export DATA_DIR="$RESOLVED_DIR/data"
CLEAN=false

while true
do
  case "$1" in
    --clean)
      CLEAN=true
      shift
      ;;
    *)
      break;;
  esac
done

setup
for PLUGIN in "$@"; do
  DESC="$DIR/plugins/$PLUGIN/descriptor.yaml"
  if [ -f "$DESC" ]; then
    parse "$DESC"
    echo "Plugin: $PLUGIN"
    if ! check_dependencies; then
      continue
    fi
    if [ $CLEAN = true ]; then
      clean "$DESC"
    fi
    download "$DESC"
    prepare "$DESC"
    build "$DESC"
    install "$DESC"
    package
  else
    echo "Plugin $PLUGIN doesn't have a descriptor"
  fi
done
