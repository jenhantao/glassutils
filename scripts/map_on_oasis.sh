#! /bin/bash
################################################################################

### SUMMARY OF FUNCTIONS ###
# One stop destination for all your mapping needs. This script, which is meant
# to be executed on the TSCC, will create qsub scripts (and execute them) to
# perform the following:
# 1. Copy raw data (fastq.gz) from the Glassome to the TSCC (without using qsub)
#    into an automatically generated directory on the Oasis file system
# 2. Decompress the files if necessary
# 3. Map the fastq files to a reference genome, producing a *.sam file
#    * using STAR or Bowtie2
# 4. Creates tag directories
# 5. Calculates the PBC coefficient - which involves removing all non-uniquely 
#    mapped reads, duplicate reads, and calculating the pileups
#    * read more about the PBC coefficient here: 
#      http://genome.ucsc.edu/ENCODE/qualityMetrics.html
# 6. Moves all files from the TSCC back to Glassome
# 7. Cleans up if neccessary
# 8. Produces a summary of executed jobs - namely which ones failed
###

### LICENSE STATEMENT ###
# Copyright (c) 2015, Jenhan Tao 
# All rights reserved. 
# 
# Redistribution and use in source and binary forms, with or without 
# modification, are permitted provided that the following conditions are met: 
#
# * Redistributions of source code must retain the above copyright notice, 
#   this list of conditions and the following disclaimer. 
# * Redistributions in binary form must reproduce the above copyright 
#   notice, this list of conditions and the following disclaimer in the 
#   documentation and/or other materials provided with the distribution. 
# * Neither the name of UC San Diego nor the names of its contributors may 
#   be used to endorse or promote products derived from this software 
#   without specific prior written permission. 
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE 
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
# POSSIBILITY OF SUCH DAMAGE. 
###

### OPTIONS AND ARGUMENTS ###
# -s <fileSource> (where the raw data is - Glassome or TSCC, default = Glassome)
# -t generate qsub scripts but do not execute them
### 

### set default options ###

fileSource="glassome"
testing=false
glassomePath="/projects/ps-glasslab-data/"

# check number of arguments
if [ $# -ne 4 ] 
then
    echo "Usage: "
    echo "map_on_oasis.sh <experiment type (chip|rna)> <genome> \
 <email> <input file directory> [optional arguments]"
    echo "Options:
-s    <fileSource> (where the raw data is - Glassome or \
TSCC, default = Glassome)
-t    generate qsub scripts but do not execute them"
    exit 1
fi

### parse the input ###

OPTIND=1
while getopts "s:t" option ; do # set $o to the next passed option
        case "$option" in  
        s)  
                fileSource=$OPTARG
        ;;  
        t)  
                testing=true
        ;;  
        esac
done

experimentType=$1
genome=$2
email=$3
inputDirectory=$4
# convert fileSource to lower case
fileSource=${fileSource,,}
###

### check arguments ###

if ! [ $fileSource == "glassome" ] || [ $fileSource == "tscc" ]
then
    echo "Error! Filesource (-s) option must be set to either glassome or tscc \
default=glassome"
    exit 1
fi

# modify the input file path if fileSource is Glassome
if [ $fileSource == "glassome" ]
then
    inputDirectory=$(readlink -fm ${glassomePath}/${inputDirectory/data//})
fi

# check that experiment type is rna (for RNA-seq) or chip (for ChIP-seq and etc)
if [ ! $experimentType == "rna" ] && [ ! $experimentType == "chip" ]
then
    echo "Error! valid choices for experiment type are 'chip' or rna' only"
    exit 1
fi

# check that the input directory exists on specified fileSource machine
if [ $fileSource == "tscc" ]
then
    if [ ! -d $inputDirectory ]
    then
        echo "Error! $inputDirectory cannot be found on the TSCC - try using \
glassome instead for the -s option" 
        exit 1
    fi    

elif [ $fileSource == "glassome" ]
then
    if [ ! -d $inputDirectory ]
    then
        echo "Error! $inputDirectory cannot be found on the Glassome - try \
using tscc instead for the -s option" 
        exit 1
    fi    
else
    echo "Error! Unknown problem with inputDirectory: $inputDirectory"
    exit 1
fi

###

### copy files to oasis ###

if ! [[ $inputDirectory == "/oasis/tscc/scratch/*" ]]
then
    outputDirectory="/oasis/tscc/scratch/$USER/${inputDirectory##*/}"
    if [ -d $outputDirectory ]
    then
        read -p "$outputDirectory already exists! Would you like to delete it\
 [yY]?" -n 1 r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]
        then
            echo "removing $outputDirectory"
            rm -rf $outputDirectory
            # do dangerous stuff
        fi
    fi
    echo "Copying files from $inputDirectory to $outputDirectory"
    scp -r $inputDirectory $outputDirectory
else
    outputDirectory=$inputDirectory
fi

###

### decompress fastq.gz files
# find fastq.gz files
compressedDirs=()
echo $outputDirectory
compressedPaths=( $(find $outputDirectory -path *fastq.gz -type f) )
for f in ${compressedPaths[*]}
do
    # remove file name to get sample directory
    compressedDir=${f%/*gz}
    # append sample directory to list
    compressedDirs[${#compressedDirs[*]}]=$compressedDir
done

# filter out duplicated directories
sampleDirs=$(echo "${compressedDirs[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')

for sample_dir in ${sampleDirs[*]}
do
    bname=`basename $sample_dir`

    # If there is exactly one fastq file, use that; otherwise...
    if ls $sample_dir/*.fastq &> /dev/null; then
        if [ `ls -l $sample_dir/*.fastq | wc -l` -ne 1 ]; then
            cat $sample_dir/*.fastq > $sample_dir/$bname.fastq_joined
            rm $sample_dir/*.fastq
            mv $sample_dir/$bname.fastq_joined $sample_dir/$bname.fastq
        fi  
        # else, only one .fastq; will be used.
    else
        # If there are any .sra files, dump to .fastq
        if ls $sample_dir/*.sra &> /dev/null; then 
            for sra in $sample_dir/*.sra
                do  
                    current_dir=`pwd`
                    # CD in so that fastq-dump works correctly
                    cd $sample_dir
                    fastq-dump $sra
                    rm $sra
                    cd $current_dir
                done
            # Then compile all the .fastq
            if [ `ls -l $sample_dir/*.fastq | wc -l` -ne 1 ]; then
                cat $sample_dir/*.fastq > $sample_dir/$bname.fastq_joined
                rm $sample_dir/*.fastq
                mv $sample_dir/$bname.fastq_joined $sample_dir/$bname.fastq
            else
                # Rename singular dumped sra file
                mv $sample_dir/*.fastq $sample_dir/$bname.fastq
            fi  
        fi  
        # Make single file, unzipping simultaneously if they are zipped
        if ls $sample_dir/*.gz &> /dev/null; then 
            zcat $sample_dir/*.gz > $sample_dir/$bname.fastq
        fi  
    fi  
done


### generate qsub scripts ###
# find directory where script is located
codebase=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ) 


###############################################################################
