#! /bin/bash
if [ "$#" -ne 2 ]; then
        echo "Illegal number of parameters"
        echo "filterToBam.sh <directory containing directories that contain sam/bam files> <output output directory>"
        exit 1
fi

inputDir=$1
outputDir=$2

# make output directory if it doesn't exist
if [ ! -d $outputDir ]
then
	mkdir $outputDir
fi


# loop for sam files
find $inputDir -name '*.sam' | while read samFile; do
	bamFile=${samFile/.sam/.nodups}
	bamFile=${bamFile##*/}
	sortedFile=${samFile/.sam/.sorted}
	sortedFile=${sortedFile##*/}
	echo "samtools sort $samFile $outputDir/$sortedFile"
	samtools sort $samFile $outputDir/$sortedFile
	echo "samtools rmdup -s $outputDir/$sortedFile $outputDir/$bamFile"
	samtools rmdup -s $outputDir/$sortedFile $outputDir/$bamFile
done

# loop for bam files
find $inputDir -name '*.bam' | while read samFile; do
	bamFile=${samFile/.bam/.nodups}
	bamFile=${samFile##*/}
	sortedFile=${samFile/.bam/.sorted}
	sortedFile=${sortedFile##*/}
	echo "samtools sort $samFile $outputDir/$sortedFile"
	samtools sort $samFile $outputDir/$sortedFile
	echo "samtools rmdup -s $outputDir/$sortedFile $outputDir/$bamFile"
	samtools rmdup -s $outputDir/$sortedFile $outputDir/$bamFile
done