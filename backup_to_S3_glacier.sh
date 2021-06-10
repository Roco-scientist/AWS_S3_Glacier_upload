#!/bin/bash


####################
# Variables to change
####################
CHUNK_SIZE=1073741824
FILE_HASH_FOLDER=/tmp/hash_files
FILE_COMBINED_HASH_FOLDER=/tmp/hashed_files_combined
FILE_CHUNK_FOLDER=/tmp/chunked_files
VAULT=pictures.backup
ARCHIVE_DESCRIPTION='"Backup of pictures"' 
ARCHIVE_FOLDER=/media/main/Pictures
ARCHIVE_FILE=/media/main/pictures.tar
TEST=true
NOT_ALREADY_SPLIT=false
NOT_TARRED=false

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
mkdir $FILE_CHUNK_FOLDER
mkdir $FILE_HASH_FOLDER
mkdir $FILE_COMBINED_HASH_FOLDER
if [ $TEST = true ];then
	echo command:
	echo split -b $CHUNK_SIZE --verbose $ARCHIVE_FILE $FILE_CHUNK_FOLDER/chunk
fi
if [ $NOT_ALREADY_SPLIT = true ];then
	split -b $CHUNK_SIZE --verbose $ARCHIVE_FILE $FILE_CHUNK_FOLDER/chunk
fi

####################
# initiate multipart upload
####################
if [ $TEST = true ];then
	echo command:
	echo aws glacier initiate-multipart-upload --account-id - --archive-description $ARCHIVE_DESCRIPTION --part-size $CHUNK_SIZE --vault-name $VAULT
else
	aws glacier initiate-multipart-upload --account-id - --archive-description $ARCHIVE_DESCRIPTION --part-size $CHUNK_SIZE --vault-name $VAULT
fi

UPLOADID=""

####################
# upload chunked files and hash
####################
echo "Uploading and hashing files"
CHUNK_START=0
CHUNK_END=0
NUMBER=1
for FILE in $FILE_CHUNK_FOLDER/chunk*; do
	FILESIZE=$(stat -c%s "$FILE")
	CHUNK_START=$CHUNK_END
	if [ $CHUNK_START != 0 ];then
		let "CHUNK_START+=1"
	fi
	let "CHUNK_END=$CHUNK_START+$FILESIZE"
	if [ $TEST = true ];then
		echo command:
		echo aws glacier upload-multipart-part --upload-id $UPLOADID --body $FILE --range "bytes $CHUNK_START-$CHUNK_END/*" --account-id - --vault-name $VAULT 
	else
		aws glacier upload-multipart-part --upload-id $UPLOADID --body $FILE --range "bytes $CHUNK_START-$CHUNK_END/*" --account-id - --vault-name $VAULT 
	fi
	printf -v PADDED_NUMBER "%02d" $NUMBER
	if [ $TEST = true ];then
	 	echo command:
		# echo "openssl dgst -sha256 -binary $FILE > $FILE_HASH_FOLDER/chunk_hash$PADDED_NUMBER"
	else
		openssl dgst -sha256 -binary $FILE > $FILE_HASH_FOLDER/chunk_hash$PADDED_NUMBER
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
	echo $DESTINATION
}

# TODO fix below.  Needs to be a tree hash, not a sequential hash
HASH_FILES=($FILE_HASH_FOLDER/chunk_hash*)
for HASH in "${HASH_FILES[@]}"; do
	if [ $HASH2 = "None" ]; then
		if [ $HASH1 = "None" ]; then
			HASH1=$HASH
		else
			HASH2=$HASH
			PREVIOUS_HASHCOMBO=$(combine_then_hash $HASH1 $HASH2 $FILE_COMBINED_HASH_FOLDER)
			if [ $TEST = true ];then
				echo command:
				echo "cat $HASH2 $HASH1 | openssl dgst -sha256 -binary > $PREVIOUS_HASHCOMBO"
			fi
		fi
	else
		PREVIOUS_HASHCOMBO=$(combine_then_hash $PREVIOUS_HASHCOMBO $HASH $FILE_COMBINED_HASH_FOLDER)
		if [ $TEST = true ];then
			echo command:
			echo "cat $PREVIOUS_HASHCOMBO $HASH | openssl dgst -sha256 -binary  > $PREVIOUS_HASHCOMBO"
		fi
	fi
done
TREEHASH_START=$(cat $PREVIOUS_HASHCOMBO $HASH | openssl dgst -sha256)
TREEHASH=$(cut -d " " -f 2 <<< "$TREEHASH_START")
echo $TREEHASH

####################
# complete upload
####################
echo "Completing upload with combined hashes"
if [ $TEST = true ];then
	echo command:
	echo aws glacier complete-multipart-upload --checksum $TREEHASH --archive-size $CHUNK_END --upload-id $UPLOADID --account-id - --vault-name $VAULT
else
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
# rm -r $FILE_COMBINED_HASH_FOLDER
