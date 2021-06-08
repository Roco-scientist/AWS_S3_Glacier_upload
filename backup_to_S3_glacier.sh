#!/bin/bash
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

# tar archive pictures
if [ $TEST = true ];then
	echo command:
	echo tar -cf $ARCHIVE_FILE $ARCHIVE_FOLDER 
fi
if [ $NOT_TARRED = true ]; then
	tar -cf $ARCHIVE_FILE $ARCHIVE_FOLDER 
fi

# split into chunks
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

# initiate multipart upload
if [ $TEST = true ];then
	echo command:
	echo aws glacier initiate-multipart-upload --account-id - --archive-description $ARCHIVE_DESCRIPTION --part-size $CHUNK_SIZE --vault-name $VAULT
else
	aws glacier initiate-multipart-upload --account-id - --archive-description $ARCHIVE_DESCRIPTION --part-size $CHUNK_SIZE --vault-name $VAULT
fi

UPLOADID=""

# upload chunked files and hash
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
		echo "openssl dgst -sha256 -binary $FILE > $FILE_HASH_FOLDER/chunk_hash$PADDED_NUMBER"
	else
		openssl dgst -sha256 -binary $FILE > $FILE_HASH_FOLDER/chunk_hash$PADDED_NUMBER
	fi
	let "NUMBER+=1"
done

# combine hashes
echo "Combining hashes"
HASH1="None"
HASH2="None"
HASHCOMBO="None"
for HASH in $FILE_HASH_FOLDER/chunk_hash*; do
	if [ $HASH1 = "None" ]; then
		if [ $HASH2 = "None" ]; then
			HASH2=$HASH
		else
			HASH1=$HASH
			HASH2_BASE="$(basename -- $HASH2)"
			HASH1_BASE="$(basename -- $HASH1)"
			HASH1_END=${HASH1_BASE: -2}
			HASHCOMBO=$FILE_COMBINED_HASH_FOLDER/$HASH2_BASE"_"$HASH1_END
			cat $HASH2 $HASH1 > $HASHCOMBO
			openssl dgst -sha256 -binary $HASHCOMBO > $HASHCOMBO"_hashed"
			if [ $TEST = true ];then
				echo command:
				echo "cat $HASH2 $HASH1 > $HASHCOMBO"
				echo command:
				echo "openssl dgst -sha256 -binary $HASHCOMBO > $HASHCOMBO"_hashed""
			fi
		fi
	else
		HASH_BASE="$(basename -- $HASH)"
		HASH_END=${HASH_BASE: -2}
		PREVIOUS_HASHCOMBO=$HASHCOMBO"_hashed"
		HASHCOMBO=$HASHCOMBO"_"$HASH_END
		cat $PREVIOUS_HASHCOMBO $HASH > $HASHCOMBO
		openssl dgst -sha256 -binary $HASHCOMBO > $HASHCOMBO"_hashed"
		if [ $TEST = true ];then
			echo command:
			echo "cat $PREVIOUS_HASHCOMBO $HASH > $HASHCOMBO"
			echo command:
			echo "openssl dgst -sha256 -binary $HASHCOMBO > $HASHCOMBO"_hashed""
		fi
	fi
done
TREEHASH_START=$(openssl dgst -sha256 $HASHCOMBO)
TREEHASH=$(cut -d " " -f2 <<< "$TREEHASH_START")
echo $TREEHASH

# complete upload
echo "Completing upload with combined hashes"
if [ $TEST = true ];then
	echo command:
	echo aws glacier complete-multipart-upload --checksum $TREEHASH --archive-size $CHUNK_END --upload-id $UPLOADID --account-id - --vault-name $VAULT
else
	aws glacier complete-multipart-upload --checksum $TREEHASH --archive-size $CHUNK_END --upload-id $UPLOADID --account-id - --vault-name $VAULT
fi

# remove hash and chunk files
echo "Cleaning up and deleting files"
if [ $TEST = false ];then
	rm -r $FILE_CHUNK_FOLDER
	rm -r $FILE_HASH_FOLDER
fi
rm -r $FILE_COMBINED_HASH_FOLDER
