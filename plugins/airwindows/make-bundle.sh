#!/bin/bash

echo "Bundle: $1 $2"

DIR=$(dirname "$1")
NAME=$(basename "$1" .so)
LNAME=$(echo "$NAME"|tr '[:upper:]' '[:lower:]')

DEST="$2"/Airwindows-"$NAME".lv2
MANIFEST="$DEST/manifest.ttl"
mkdir "$DEST"
cp "$DIR/$NAME".* "$DEST"
{
  echo "@prefix lv2:  <http://lv2plug.in/ns/lv2core#> ."
  echo "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> ."
  echo -n "<https://hannesbraun.net/ns/lv2/airwindows/"
  echo -n "$LNAME"
  echo ">"
  echo "a lv2:Plugin ; lv2:binary <$NAME.so> ; rdfs:seeAlso <$NAME.ttl> ."
} > "$MANIFEST"
