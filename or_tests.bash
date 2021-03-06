#!/bin/bash
#
# This script tests OpenROAD functionality.
#   It has to be run in an OpenROAD environment (II_SYSTEM, PATH, etc. should be set)
#   Ingres/Net and OR Server should  be running.
#   The parameter passed is the database (incl. vnode) used for the tests.
# USAGE:
#        or_tests.bash <dbname> [<testno>]
#

# -----------------------------------------------------------------------------
# Function TEST_CLEANUP
#   This function performs the cleanup (deletion of files) and exit of the script.
#   Parameter passed is the exit code to be returned to the shell.
# ------------------------------------------------------------------------------
TEST_CLEANUP()
{
    return_code=$1
    if [ -d $TESTDIR ]
    then
        cd $TESTDIR
        rm -f *.img *.cfg ignore_apps.lst
#       Remove OpenROAD XML export files (XML files containing an <OPENROAD> element).
#       Note: The test stats XML file (if OR_UNITTEST_GEN_XML_STATS=TRUE)
#             is not an export file, thus it will not be deleted.
        for utxml in $(grep -l "^<OPENROAD " *.xml)
        do
            rm -f $utxml
        done
    fi
    exit $return_code
}

TEST_CHECKCMD()
{
# -----------------------------------------------------------------------------
# Function TEST_CHECKCMD
#   First parameter passed is the return code of the last command executed.
#   Second parameter passed is the expected return code.
#   Third parameter:
#       Y: Indicates an error is deemed as critical
#       N: Any errors are reported, but not as critical
#   Remaining parameters give a brief description of what the command was doing.
# ------------------------------------------------------------------------------
   h_clf_return_code=$1
   shift

   h_clf_return_code_expected=$1
   shift

   h_clf_critical=$1
   shift

   h_clf_command=$*

   if [ $h_clf_return_code -ne $h_clf_return_code_expected ]
   then
      printf "++ ERROR ++\n%s\n" "$h_clf_command"
      printf "+++ Status Code: expected: %s, actual: %s\n\n" $h_clf_return_code_expected $h_clf_return_code

      if [ "$h_clf_critical" = "Y" ]
      then
         TEST_CLEANUP 1
      else
          ((rv++))
      fi
   fi

   return 0
}

# -----------------------------------------------------------------------------
#       Main execution
# -----------------------------------------------------------------------------

rv=0

cd $(dirname $0)
export SCRIPTDIR=`pwd`

if [ $# -lt 1 ]
then
    printf "USAGE:\n\t$0 <dbname> [<testno>]\n\n"
    exit 1
fi
if [ -z "$1" ]
then
    printf "Empty <dbname> supplied!\n\n"
    exit 1
fi
export TESTDB=$1
if [ -z "$2" ]
then
    export TESTNO=$(date +"%y%m%d%H%M%S")
else
    export TESTNO=$2
fi

export TESTDIR=$SCRIPTDIR/tests/test${TESTNO}

echo '\q' | tm -S $TESTDB
TEST_CHECKCMD $? 0 "Y" "Unable to connect to ${TESTDB}"

mkdir -p $TESTDIR
TEST_CHECKCMD $? 0 "Y" "Unable to create test directory $TESTDIR"

export II_LOG=.
export II_W4GL_EXPORT_INDENTED=TRUE
unset II_W4GL_EXPORT_COMMENT

cygwin=false
if [ `uname | grep "^CYGWIN"` ]
then
    cygwin=true
fi

if [ -f ${SCRIPTDIR}/custom_preimport.bash ]
then
    bash ${SCRIPTDIR}/custom_preimport.bash
    rv=$?
    if [ $rv -lt 0 ]
    then
#   critical error detected
        TEST_CLEANUP $rv
    fi
fi

printf "\nOR Unit tests:\n"

cd $TESTDIR
TEST_CHECKCMD $? 0 "Y" "Unable to change into ${TESTDIR}"
rm -f *.xml
cp -r ${SCRIPTDIR}/unittests/* .
TEST_CHECKCMD $? 0 "Y" "Unable to copy unittests files into test directory ${TESTDIR}"

if [ -z "$OR_UNITTEST_GEN_XML_STATS" ]
then
	genxmlstats=FALSE
else
	genxmlstats=`echo "${OR_UNITTEST_GEN_XML_STATS}" | tr [a-z] [A-Z]`
fi
if [ "$genxmlstats" = "TRUE" ]
then
	if [ -z "$OR_UNITTEST_STATSFILE_XML" ]
	then
		teststats=${TESTDIR}/orunitteststats.xml
	else
		if $cygwin
		then
			teststats=`cygpath --unix ${OR_UNITTEST_STATSFILE_XML}`
		else
			teststats=${OR_UNITTEST_STATSFILE_XML}
		fi
	fi
else
	if [ -z "$OR_UNITTEST_STATSFILE" ]
	then
		teststats=${TESTDIR}/orunitteststats.log
	else
		if $cygwin
		then
			teststats=`cygpath --unix ${OR_UNITTEST_STATSFILE}`
		else
			teststats=${OR_UNITTEST_STATSFILE}
		fi
	fi
fi
rm -f ${teststats}

if $cygwin
then
    display_log_file=`cygpath --windows ${TESTDIR}/orunittest.log`
	display_stats_file=`cygpath --windows ${teststats}`
else
    display_log_file=${TESTDIR}/orunittest.log
	display_stats_file=${teststats}
fi
printf " Logfile %s ...\n" ${display_log_file}
printf " Statistics file %s ...\n\n" ${display_stats_file}

rc=0

w4gldev backupapp in ${TESTDB} UnitTestFramework UnitTestFramework.xml -nreplace -xml -nowindows -Lorunittest.log -Tyes,logonly
if [ $? -ne 0 ]
then
    printf "\nUnable to import application UnitTestFramework into ${TESTDB}.\n"
    TEST_CLEANUP 1
fi

for utxml in $(ls *.xml | grep -v "^UnitTestFramework\.xml" | grep -v "^UnitTestRunner\.xml" | sort)
do
    utapp=$(basename $utxml .xml)
#   remove any locks for this app, as they would prevent importing
    tm -S ${TESTDB} <<EOF
\sql
DELETE FROM ii_locks WHERE entity_id IN (SELECT entity_id FROM ii_entities WHERE folder_id IN
(SELECT entity_id FROM ii_entities WHERE entity_type='appsource' AND lowercase(entity_name)=lowercase('${utapp}')));
DELETE FROM ii_locks WHERE entity_id IN (SELECT entity_id FROM ii_entities WHERE entity_type='appsource' AND lowercase(entity_name)=lowercase('${utapp}'));
COMMIT;\g\q
EOF

    w4gldev backupapp in ${TESTDB} $utapp $utxml -nreplace -xml -nowindows -Lorunittest.log -Tyes,logonly -A
    rv1=$?
    if [ $rv1 -eq 0 ]
    then
        printf " ${utapp}: ... "
        if [ -f ignore_apps.lst ]
        then
            grep -w -i ${utapp} ignore_apps.lst > /dev/null && {
                printf "IGNORED\n"
                continue
            }
        fi

        runner=""
        runflags=""
        makeimageflags=""
        runtimeout=""

        if [ -f ${utapp}.cfg ]
        then
            runner=`grep "^RUNNER=" ${utapp}.cfg | cut -f2 -d'=' | tr -d $'\r'`
            runflags=`grep "^RUNFLAGS=" ${utapp}.cfg | cut -f2 -d'=' | tr -d $'\r'`
            makeimageflags=`grep "^MAKEIMAGEFLAGS=" ${utapp}.cfg | cut -f2 -d'=' | tr -d $'\r'`
            runtimeout=`grep "^RUNTIMEOUT=" ${utapp}.cfg | cut -f2 -d'=' | tr -d $'\r'`
        fi

        if [ -z "$runtimeout" ]
        then
	        runtimeout=300
        fi
        if [ -z "$runner" ]
        then
            runcmd="w4gldev rundbapp ${TESTDB} $utapp -nowindows -Lorunittest.log -Tyes,logonly -A ${runflags}"
        else
            if [ "$runner" = "runimage" ]
            then
                w4gldev makeimage ${TESTDB} $utapp ${utapp}.img -nowindows -Lorunittest.log -Tyes,logonly -A ${makeimageflags}
                if [ $? -ne 0 ]
                then
                    printf "makeimage of application FAILED.\n"
                    ((rc++))
                    continue
                fi
                runcmd="w4gldev runimage ${utapp}.img -nowindows -Lorunittest.log -Tyes,logonly -A ${runflags}"
            else
# Run your own script to execute the test - passing application name as parameter (TESTDB and TESTDIR are set in environment)
                runcmd="${runner} $utapp"
            fi
        fi

        bash ${SCRIPTDIR}/timeout_cmd.bash ${runtimeout} ${runcmd}
        rv2=$?
        if [ $rv2 -eq 0 ]
        then
            printf "OK.\n"
        else
			if [ $rv2 -eq 2 ]
			then
				printf "OK (Some/or all tests have been SKIPPED).\n"
			else
				if [ $rv2 -eq 124 ]
				then
					printf "FAILED (due to timeout after ${runtimeout} seconds).\n"
				else
					printf "FAILED.\n"
				fi
				((rc++))
			fi
        fi
    else
        printf " ${utapp}: Import of application FAILED.\n"
        ((rc++))
    fi
done

printf "\nTest Statistics: %s\n" ${display_stats_file}
printf "Detailed log: %s\n" ${display_log_file}

if [ $rc -ne 0 ]
then
   printf "\nOR Unit Tests completed. ERROR(s) encountered in %s unit test suite(s).\n" $rc
   TEST_CLEANUP $rc
else
    printf "\nOR Unit Tests successfully executed.\n"
    TEST_CLEANUP 0
fi
