#!/bin/bash -x

# --------------------------------------------------------------------------------------------------------------
#
# This script will submit the input file specified to ORCA via the slurm scheduler. The script will automatically
# create a new output directory with the same title as the input file and send all files there. Script timing 
# will be recorded in the slurm.out file which will be copied to the output directory only when the job has 
# completed. Email status updates will be sent to the address selected.
#
# --------------------------------------------------------------------------------------------------------------

# configure email notifications
#SBATCH --mail-user=jdstates@mines.edu # must manually edit this in the template
#SBATCH --mail-type=BEGIN # get email when job starts
#SBATCH --mail-type=END # get email when job ends
#SBATCH --mail-type=FAIL # get email when job fails
#SBATCH --mail-type=REQUEUE # get email when job requeues
#SBATCH --mail-type=ALL # use all of the above...

#SBATCH --account=2101080209 # you can find the account number by running $ sacctmgr show Account
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=36
#SBATCH --ntasks=36
#SBATCH --export=ALL
#SBATCH --time=23:59:59 # time when job will automatically terminate- want the smallest possible overestimate
maxtime=3585 # buffer time to allow cleanup, should be ~10 seconds less than auto termination time

# --------------------------------------------------------------------------------------------------------------

INPUT_FILE="C-Cl-F-F_radical.inp"

# --------------------------------------------------------------------------------------------------------------

# record submission time
mystart=`date +%Y-%m-%d %H:%M:%S`

# make a new output folder with the job name as the title and direct the output there
OUTPUT_DIR="${SLURM_SUBMIT_DIR}/${SLURM_JOB_NAME: 0:-2}"
mkdir -p ${OUTPUT_DIR}_IN-PROGRESS

# copy the input file to the output folder and delete the copy in the submit directory
cp ${SLURM_SUBMIT_DIR}/${INPUT_FILE} ${OUTPUT_DIR}_IN-PROGRESS/${INPUT_FILE}
rm ${SLURM_SUBMIT_DIR}/${INPUT_FILE}

# copy the input script to the output folder and delete the copy in the submit directory
cp ${SLURM_SUBMIT_DIR}/${SLURM_JOB_NAME} ${OUTPUT_DIR}_IN-PROGRESS/${SLURM_JOB_NAME}
rm ${SLURM_SUBMIT_DIR}/${SLURM_JOB_NAME}

# load and export NBO path
ml libs/lapack/gcc
ml libs/openblas
ml apps/nbo/7
export NBOEXE=/sw/apps/nbo/7/bin/nbo7.i4.exe

# configure KMP_AFFINITY to communicate hardware threads to OMP parallelizer
export KMP_AFFINITY=respect,verbose

# load the orca module and print JOBID to slurm out for debugging
ml compilers/gcc mpi/openmpi/gcc-cuda apps/orca/openmpi/5.0.4
JOBID=`echo $SLURM_JOBID`

# configure and pass OMP parameters
#export OMP_NUM_THREADS=1

# go the output folder
cd ${OUTPUT_DIR}_IN-PROGRESS

# run the input file and generate an output file of the same name
# if the timeout is reached it will return exit 124, otherwise it returns the calc exit status
start=`date +%s.%N`
OUTPUT_FILE=${INPUT_FILE: 0:-4}.out
timeout -s SIGTERM $maxtime orca ${OUTPUT_DIR}_IN-PROGRESS/${INPUT_FILE}>${OUTPUT_FILE}
CALC_STATUS=$?
end=`date +%s.%N`


# try to generate the orbital *.cube files and *.html files if the ORCA job was successful
# also try to extract the NBO output (not always called, will pass if no NBO)
if [[ $CALC_STATUS == 0 ]]; then 
	cubegen=$HOME/scratch/MyScripts/orca_orbital_cubegen.s
	chmod +x "$cubegen"
	"$cubegen" -f ${INPUT_FILE: 0:-4}_opt.gbw || echo "MO VISUALIZATION FAILED"

	sed -n '/Now starting NBO\.\.\./,/returned from  NBO  program/p' ${OUTPUT_FILE} | tail -n +2 | head -n -1 > ${INPUT_FILE: 0:-4}.nbout || echo "NBO SCRAPING FAILED"
fi

# get the job status
if [[ $CALC_STATUS == 124 ]]; then 
	status="TIMEOUT"
elif [[ $CALC_STATUS != 0 ]]; then
	status="ERROR"
elif [[ $CALC_STATUS == 0 ]]; then
	status="NORMAL"
fi

# log the time for benchmarking in the outputfile
runtime=$( echo "$end - $start" | bc -l )
echo $runtime
exec 3>>${OUTPUT_FILE}
echo "">&3
echo "slurmID:    ${SLURM_JOBID}">&3
echo "totalRuntime[s]:    ${runtime}">&3
exec 3>&-

# get the number of basis functions used in the first calculation by the SHARK package
myBasis=$(grep -m 1 "Number of basis functions" ${OUTPUT_FILE} | awk '{print $NF}' | tr -d '[:space:]')
myBasis=($myBasis)

# record the completion time
myend=`date +%Y-%m-%d %H:%M:%S`

# write the total job timing to the job_timings file in the submit directory as a CSV
cd ${SLURM_SUBMIT_DIR}
if [ ! -f job_timings.csv ]; then
	echo "filename,slurmID,nbasisfuncs,start,end,runtime[s],jobstatus" > job_timings.csv
fi
exec 3>>job_timings.csv
echo "${INPUT_FILE},${SLURM_JOBID},${myBasis},${mystart},${myend},${runtime},${status}">&3
exec 3>&-


# copy the slurm output to the output folder and delete from the submit directory
cp ${SLURM_SUBMIT_DIR}/slurm-${SLURM_JOBID}.out ${OUTPUT_DIR}_IN-PROGRESS/slurm-${SLURM_JOBID}-${INPUT_FILE: 0:-4}.out
rm ${SLURM_SUBMIT_DIR}/slurm-${SLURM_JOBID}.out


# rename the output directory appropriately
if [[ $CALC_STATUS == 124 ]]; then 

	mv ${OUTPUT_DIR}_IN-PROGRESS ${OUTPUT_DIR}_TIMEOUT
	exit 124

elif [[ $CALC_STATUS != 0 ]]; then

	mv ${OUTPUT_DIR}_IN-PROGRESS ${OUTPUT_DIR}_ERROR
	exit 2

elif [[ $CALC_STATUS == 0 ]]; then

	mv ${OUTPUT_DIR}_IN-PROGRESS ${OUTPUT_DIR}
	exit 0
fi




