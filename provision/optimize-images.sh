#!/bin/bash
# From https://gist.github.com/julianxhokaxhiu/c0a8e813eabf9d6d9873

# Use -d to pass in the directory, or else the current directory is used
# Ex: ./optimize-images.sh -d /srv/www/mysite/public_html/wp-content/uploads/

# Check to make sure pngquant and jpegoptim are installed by running each command. If not installed, run
# sudo apt-get install pngquant jpegoptim

# Optional default values for optional flags
DIR=$(pwd)
MAXQUALITY="60"
CONVERTPNG=false

while getopts 'd:q:c:' c
do
  case $c in
    d) DIR="$OPTARG" ;;
    q) MAXQUALITY="$OPTARG" ;;
    c) CONVERTPNG="$OPTARG" ;;
  esac
done

#echo "$DIR"
#echo "$MAXQUALITY"
#echo "$CONVERTPNG"

if [ "$CONVERTPNG" != false ]; then
  # Convert actual PNGs to JPGs
  echo "Converting actual PNGs files to JPG"
  find "$DIR" -type f -name "*.png" | sed 's/\.png$//' | xargs -I% convert -quality "$MAXQUALITY" "%.png" "%.jpg"
  find "$DIR" -type f -name "*.png" -exec rm {} +
fi

# Convert fake jpgs to jpgs (files that are actually png but have .jpg filename)
# Use imagemagicks convert command
find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -exec convert {} {} \;

# Optimize JPGs
find "$DIR" -type f -iname "*.png" -exec pngquant -f --ext .png --verbose --quality 0-"$MAXQUALITY" -s 1 -- {} \;
# Optimize PNGs
find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -exec jpegoptim -m"$MAXQUALITY" -f --strip-all {} \;
