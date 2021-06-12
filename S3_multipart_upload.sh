#!/bin/bash

####################
# Variables to change
####################

CHUNK_SIZE=262144000
STORAGE_CLASS=STANDARD
FILE_CHUNK_FOLDER=/tmp/split
CHUNK_ID=chunk
TEST=false


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

while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
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

if [ -z "$UPLOAD_FILE" ];then echo "--input required";exit 1; fi
if [ ! -f "$UPLOAD_FILE" ];then echo "input file does not exist";exit 1; fi
if [ -z "$BUCKET" ];then echo "--bucket required";exit 1; fi

####################
# Setup directories
####################

mkdir $FILE_CHUNK_FOLDER

####################
# split into chunks
####################

echo "Splitting file into $CHUNK_SIZE byte chunks"
echo split -b $CHUNK_SIZE --verbose $UPLOAD_FILE $FILE_CHUNK_FOLDER/$CHUNK_ID
# split -b $CHUNK_SIZE --verbose $UPLOAD_FILE $FILE_CHUNK_FOLDER/$CHUNK_ID

####################
# initiate multipart upload on S3 glacier
####################

KEY="$(basename -- $UPLOAD_FILE)"
echo aws s3api create-multipart-upload --storage-class $STORAGE_CLASS --key $KEY --bucket $BUCKET
if [ $TEST = false ];then
	UPLOADID=$(aws s3api create-multipart-upload --storage-class $STORAGE_CLASS --key $KEY --bucket $BUCKET | grep UploadId | sed 's/.*UploadId\"\: //' | sed 's/\"//g')
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
echo "{\"Parts\": [" > mpustruct
for FILE in $FILE_CHUNK_FOLDER/$CHUNK_ID*; do
	if [ $NUMBER -ge 2 ]; then
		echo "," >> mpustruct
	fi
	echo aws s3api upload-part --body $FILE --key $KEY --part-number $NUMBER --upload-id $UPLOADID --bucket $BUCKET
	if [ $TEST = false ];then
		ETAG=$(aws s3api upload-part --body $FILE --key $KEY --part-number $NUMBER --upload-id $UPLOADID --bucket $BUCKET | grep ETag | sed 's/.*ETag\": //' | sed 's/\\"//g' | sed 's/\"//g')
	fi
	echo "{" >> mpustruct
	echo "\"ETag\": \"$ETAG\"," >> mpustruct
	echo "\"PartNumber\": $NUMBER" >> mpustruct
	echo "}" >> mpustruct
	let "NUMBER+=1"
done
echo "]}" >> mpustruct

####################
# complete upload
####################

echo "Completing upload"
echo aws s3api complete-multipart-upload --bucket $BUCKET --key $KEY --upload-id $UPLOADID
if [ $TEST = false ];then
	aws s3api complete-multipart-upload --bucket $BUCKET --key $KEY --upload-id $UPLOADID --multipart-upload file://mpustruct
fi

####################
# remove chunk files
####################
echo "Cleaning up and deleting files"
if [ $TEST = false ];then
	rm -r $FILE_CHUNK_FOLDER
	rm mpustruct
fi
