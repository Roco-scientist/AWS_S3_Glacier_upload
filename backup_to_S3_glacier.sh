#!/bin/bash

####################
# Variables to change
####################

CHUNK_SIZE=1073741824
FILE_HASH_FOLDER=/tmp/hash_files
FILE_CHUNK_FOLDER=/tmp/chunked_files
VAULT=pictures.backup
ARCHIVE_DESCRIPTION='"Backup of pictures"' 
ARCHIVE_FOLDER=/media/main/Pictures
ARCHIVE_FILE=/media/main/pictures.tar
TEST=true
NOT_ALREADY_SPLIT=false
NOT_TARRED=false
CHUNK_ID=chunk

arg_info () {
	echo "usage: backup_to_S3_glacier [-c|--chunk <size>] [-v|--vault <S3 Glacier vault>] [-d|--description <File description>] [-i|--input <file>]"
	echo ""
	echo "Splits and uploads a file to S3 Glacier"
	echo ""
	echo "    --chunk 		byte size of splits to upload to S3 [default=$CHUNK_SIZE]"
	echo "    --vault 		S3 bucket destination [default=$VAULT]"
	echo "    --description 	Archive description"
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
      -b|--bucket)
      VAULT="$2"
      shift # past argument
      shift # past value
      ;;
      -d|--description)
      ARCHIVE_DESCRIPTION="$2"
      shift # past argument
      shift # past value
      ;;
      -i|--input)
      ARCHIVE_FILE="$2"
      shift # past argument
      shift # past value
      ;;
  esac
done

if [ -z "$ARCHIVE_FILE" ];then echo "--input required";exit 1; fi
if [ ! -f "$ARCHIVE_FILE" ];then echo "input file does not exist";exit 1; fi
if [ -z "$VAULT" ];then echo "--vault required";exit 1; fi

####################
# Setup directories
####################

mkdir $FILE_CHUNK_FOLDER
mkdir $FILE_HASH_FOLDER

####################
# tar archive pictures
####################

if [ $TEST = true ];then
	echo command:
	echo tar -cf $ARCHIVE_FILE $ARCHIVE_FOLDER 
fi
if [ $NOT_TARRED = true ]; then
	tar -cf $ARCHIVE_FILE $ARCHIVE_FOLDER 
fi

####################
# split into chunks
####################

echo "Splitting file into $CHUNK_SIZE byte chunks"
if [ $TEST = true ];then
	echo command:
	echo split -b $CHUNK_SIZE --verbose $ARCHIVE_FILE $FILE_CHUNK_FOLDER/$CHUNK_ID
fi
if [ $NOT_ALREADY_SPLIT = true ];then
	split -b $CHUNK_SIZE --verbose $ARCHIVE_FILE $FILE_CHUNK_FOLDER/$CHUNK_ID
fi

####################
# initiate multipart upload on S3 glacier
####################

echo aws glacier initiate-multipart-upload --account-id - --archive-description $ARCHIVE_DESCRIPTION --part-size $CHUNK_SIZE --vault-name $VAULT
if [ $TEST = false ];then
	UPLOADID=$(aws glacier initiate-multipart-upload --account-id - --archive-description $ARCHIVE_DESCRIPTION --part-size $CHUNK_SIZE --vault-name $VAULT | grep UploadId | sed 's/.*UploadId\"\: //' | sed 's/\"//g')
else
	UPLOADID=""
fi


####################
# upload chunked files and hash
####################

echo "Uploading and hashing files"
CHUNK_START=0
CHUNK_END=0
NUMBER=1
for FILE in $FILE_CHUNK_FOLDER/$CHUNK_ID*; do
	FILESIZE=$(stat -c%s "$FILE")
	CHUNK_START=$CHUNK_END
	if [ $CHUNK_START != 0 ];then
		let "CHUNK_START+=1"
	fi
	let "CHUNK_END=$CHUNK_START+$FILESIZE"
	echo aws glacier upload-multipart-part --upload-id $UPLOADID --body $FILE --range "bytes $CHUNK_START-$CHUNK_END/*" --account-id - --vault-name $VAULT 
	if [ $TEST = false ];then
		aws glacier upload-multipart-part --upload-id $UPLOADID --body $FILE --range "bytes $CHUNK_START-$CHUNK_END/*" --account-id - --vault-name $VAULT 
	fi
	printf -v PADDED_NUMBER "%02d" $NUMBER
	echo "openssl dgst -sha256 -binary $FILE > $FILE_HASH_FOLDER/$CHUNK_ID"_hash"$PADDED_NUMBER"
	if [ $TEST = false ];then
		openssl dgst -sha256 -binary $FILE > $FILE_HASH_FOLDER/$CHUNK_ID"_hash"$PADDED_NUMBER
	fi
	let "NUMBER+=1"
done

####################
# combine hashes
####################

echo "Combining hashes"
HASH1="None"
HASH2="None"
HASHCOMBO="None"

combine_then_hash () {
	# combine_then_hash left_hash right_hash destination_folder
	HASH1_BASE="$(basename -- $1)"
	HASH2_END=$(sed 's/.*hash\(.*\)/\1/' <<< $2)
	DESTINATION=$3/$HASH1_BASE"_"$HASH2_END
	cat $1 $2 | openssl dgst -sha256 -binary > $DESTINATION
	echo "cat $1 $2 | openssl dgst -sha256 -binary > $DESTINATION"
}

combine_hash_directory () {
	# combine_hash_directory HASH_DIR
	HASH_FILES=($1/$CHUNK_ID*)
	FILE_NUM=${#HASH_FILES[@]}
	echo "Num files: $FILE_NUM"
	if [ $FILE_NUM = 1 ]; then
		return 125
	fi
	if [ $((FILE_NUM%2)) -eq 1 ]; then
		mv ${HASH_FILES[-1]} $LEAF_DIRECTORY
		let "FILE_NUM-=1"
	fi

	for (( INDEX=0; INDEX<$FILE_NUM; INDEX+=2 )); do
		let "SECOND_INDEX=$INDEX+1"
		combine_then_hash ${HASH_FILES[$INDEX]} ${HASH_FILES[$SECOND_INDEX]} $LEAF_DIRECTORY
	done
}
TREELEVEL=1
LEAF_DIRECTORY=$FILE_HASH_FOLDER/$TREELEVEL
mkdir $LEAF_DIRECTORY
combine_hash_directory $FILE_HASH_FOLDER
EXIT_STATUS=$?
let "TREELEVEL+=1"

while [ $EXIT_STATUS -eq 0 ]; do
	FINAL_DIR=$PREVIOUS_LEAF_DIRECTORY
	PREVIOUS_LEAF_DIRECTORY=$LEAF_DIRECTORY
	LEAF_DIRECTORY=$FILE_HASH_FOLDER/$TREELEVEL
	mkdir $LEAF_DIRECTORY
	combine_hash_directory $PREVIOUS_LEAF_DIRECTORY
	EXIT_STATUS=$?
	let "TREELEVEL+=1"
done

HASH_FILES=($FINAL_DIR/*)
echo "cat ${HASH_FILES[0]} ${HASH_FILES[1]} | openssl dgst -sha256"
TREEHASH_START=$(cat ${HASH_FILES[0]} ${HASH_FILES[1]} | openssl dgst -sha256)
TREEHASH=$(cut -d " " -f 2 <<< "$TREEHASH_START")

####################
# complete upload
####################

echo "Completing upload with combined hashes"
echo aws glacier complete-multipart-upload --checksum $TREEHASH --archive-size $CHUNK_END --upload-id $UPLOADID --account-id - --vault-name $VAULT
if [ $TEST = false ];then
	aws glacier complete-multipart-upload --checksum $TREEHASH --archive-size $CHUNK_END --upload-id $UPLOADID --account-id - --vault-name $VAULT
fi

####################
# remove hash and chunk files
####################

echo "Cleaning up and deleting files"
if [ $TEST = false ];then
	rm -r $FILE_CHUNK_FOLDER
	rm -r $FILE_HASH_FOLDER
fi
