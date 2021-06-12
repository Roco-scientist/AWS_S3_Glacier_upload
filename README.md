# AWS Glacier upload
Script/s for breaking up files and uploading them to AWS S3 Glacier storage for long term backup
<br>
<br>

## Table of Contents
<ul>
    <li><a href=#Requirements>Requirements</a></li>
<li><a href=#setup>Setup</a></li>
<li><a href=#run>Run</a></li>
</ul>
<br>

## Requirements
<ul>
<li>AWS account</li>
<li>AWS IAM user with billing privelages</li>
<li>AWS CLI</li>
<li>S3 bucket to upload to</li>
</ul>
<br>

## Setup
Change initial variables within `backup_to_S3_glacier.sh` or `S3_multipart_upload.sh` to reflect needs

## Run
Still in testing phase:<br>
`$ ./backup_to_S3_glacier.sh --chunk <size> --vault <S3 Glacier vault> --description <File description> --input <file>`
<br>
Working but uploads to S3 and not S3 Glacier, will also work with other storage classes:<br>
`$ ./S3_multipart_upload.sh --chunk <size> --storage-class GLACIER --bucket <S3 bucket> --input <file>`
