# usage
# sh a.sh 2016-03-23-IO.markdown linux-io
name=$1
imagepath=$2
mkdir $imagepath
words=`grep '\/image' ../_todoblog/$name | awk -F "\/image\/" '{print $2}' | awk -F ')' '{print $1}'`
for path in $words; do
	mv $path $imagepath
	echo "move $path into $imagepath"
done

sed -i "" "s:/image/:/image/${imagepath}/:" ../_todoblog/$name
