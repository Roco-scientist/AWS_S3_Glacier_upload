#!/bin/bash

set -e # exit if any commands fail

####################
# Variables to change
####################

CHUNK_SIZE=262144000 # default to 250mb chunks
STORAGE_CLASS=STANDARD # default to standard storage class
FILE_CHUNK_FOLDER=/tmp/split # folder file is split into
CHUNK_ID=chunk # prefix for split files.  this disappears and is unimportant
TEST=false # set to true if the code wants to be checked before uploading

####################
# Argument variables
####################

arg_info () {
	echo "usage: S3_multipart_upload [-c|--chunk <size>] [-s|--storage-class <S3 class>] [-b|--bucket <S3 bucket>] [-i|--input <file>]"
	echo ""
	echo "Splits and uploads a file to S3"
	echo ""
	echo "    --chunk 		byte size of splits to upload to S3 [default=$CHUNK_SIZE]"
	echo "    --storage-class 	S3 storage class.  Options:STANDARD, REDUCED_REDUNDANCY, "
	echo "    			STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER,"
	echo "    			DEEP_ARCHIVE, OUTPOSTS [default=$STORAGE_CLASS]"
	echo "    --bucket 		S3 bucket destination"
	echo "    --input 		input file to be split and uploaded"
	echo ""
}

while [[ $# -gt 0 ]]; do # while there are more than 0 arguments left
  KEY="$1" # assign the argument to key

  case $KEY in # if key is in any of the following, set the variable
      -h|--help)
      arg_info
      exit 0
      ;;
      -c|--chunk)
      CHUNK_SIZE="$2"
      shift # past argument
      shift # past value
      ;;
      -s|--storage-class)
      STORAGE_CLASS="$2"
      shift # past argument
      shift # past value
      ;;
      -b|--bucket)
      BUCKET="$2"
      shift # past argument
      shift # past value
      ;;
      -i|--input)
      UPLOAD_FILE="$2"
      shift # past argument
      shift # past value
      ;;
  esac
done

if [ -z "$UPLOAD_FILE" ];then echo "--input required";exit 1; fi # if UPLOAD_FILE is empty, exit
if [ ! -f "$UPLOAD_FILE" ];then echo "input file does not exist";exit 1; fi # if UPLOAD_FILE is not a file, exit
if [ -z "$BUCKET" ];then echo "--bucket required";exit 1; fi  # if BUCKET is empty, exit

####################
# Setup directories
####################

mkdir $FILE_CHUNK_FOLDER

####################
# split into chunks
####################

echo "Splitting file into $CHUNK_SIZE byte chunks"
echo split -b $CHUNK_SIZE --verbose $UPLOAD_FILE $FILE_CHUNK_FOLDER/$CHUNK_ID
split -b $CHUNK_SIZE --verbose $UPLOAD_FILE $FILE_CHUNK_FOLDER/$CHUNK_ID

####################
# initiate multipart upload on S3 glacier
####################

FILENAME="$(basename -- $UPLOAD_FILE)" # Give the S3 file the same name as the split file
echo aws s3api create-multipart-upload --storage-class $STORAGE_CLASS --key $FILENAME --bucket $BUCKET
if [ $TEST = false ];then
	# upload-id is returned within a JSON by the create-multipart-upload-command.  Need to capture that for the other commands
	UPLOADID=$(aws s3api create-multipart-upload --storage-class $STORAGE_CLASS --key $FILENAME --bucket $BUCKET | grep UploadId | sed 's/.*UploadId\"\: //' | sed 's/\"//g')
else
	UPLOADID=""
fi

####################
# upload chunked files
####################

echo "Uploading"
CHUNK_START=0
CHUNK_END=0
NUMBER=1
# Create the JSON mpustruct file, which is used to associate parts to etags when the upload is finalized to check for non-corrupt uploads
echo "{\"Parts\": [" > mpustruct
# Upload each split file
for FILE in $FILE_CHUNK_FOLDER/$CHUNK_ID*; do
	if [ $NUMBER -ge 2 ]; then
		echo "," >> mpustruct
	fi
	echo aws s3api upload-part --body $FILE --key $FILENAME --part-number $NUMBER --upload-id $UPLOADID --bucket $BUCKET
	if [ $TEST = false ];then
		# the etag is returned by the upload-part command.  This needs to be captured and put into the mpustruct file
		ETAG=$(aws s3api upload-part --body $FILE --key $FILENAME --part-number $NUMBER --upload-id $UPLOADID --bucket $BUCKET | grep ETag | sed 's/.*ETag\": //' | sed 's/\\"//g' | sed 's/\"//g')
	fi
	# Add the JSON elements to mpustruct informing ETag and PartNumber for the part upload
	echo "{" >> mpustruct
	echo "\"ETag\": \"$ETAG\"," >> mpustruct
	echo "\"PartNumber\": $NUMBER" >> mpustruct
	echo "}" >> mpustruct
	let "NUMBER+=1"
done
echo "]}" >> mpustruct # Finalise the mpustruct JSON

####################
# complete upload
####################

echo "Completing upload"
echo aws s3api complete-multipart-upload --bucket $BUCKET --key $FILENAME --upload-id $UPLOADID
if [ $TEST = false ];then
	aws s3api complete-multipart-upload --bucket $BUCKET --key $FILENAME --upload-id $UPLOADID --multipart-upload file://mpustruct
fi

####################
# remove chunk files
####################
echo "Cleaning up and deleting files"
if [ $TEST = false ];then
	rm -r $FILE_CHUNK_FOLDER
	rm mpustruct
fi
