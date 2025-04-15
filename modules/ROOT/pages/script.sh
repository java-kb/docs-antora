shopt -s globstar
for i in **/*.adoc
do 
   DIR="$(dirname "${i}")"
   
   image=":figures: $DIR";
   echo  $image;
   sed -i '2i'":figures: $DIR" $i
done