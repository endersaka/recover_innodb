#!/bin/sh

SRCDB=""
SRCDBDIR=""
DB=""
DBDIR=""

# Get the arguments passed to the command.
while [ "$1" != "" ]
do
	case $1 in
		( -b|--base-dir )
		if [[ -n "$2" ]]
		then
			DBDIR="$2"
			shift 2
			continue
		else
			echo "ERROR: need a base directory! (-b base_dir_path)"
			exit 1
		fi
		;;
		( -c|--source-base-dir )
		if [[ -n "$2" ]]
		then
			SRCDBDIR="$2"
			shift 2
			continue
		else
			echo "ERROR: need a base directory! (-d src_dir_path)"
			exit 1
		fi
		;;
		( -d|--database )
		if [[ -n "$2" ]]
		then
			DB="$2"
			shift 2
			continue
		else
			echo "ERROR: need a database! (-d db_name)"
			exit 1
		fi
		;;
		( -s|--source-database )
		if [[ -n "$2" ]]
		then
			SRCDB="$2"
			shift 2
			continue
		else
			echo "ERROR: need a source database! (-s db_name)"
			exit 1
		fi
		;;
		( -- )				# End of all options.
		shift
		break
		;;
		( -?* )
		echo "WARNING: Unknown option (ignored): $1"
		exit 1
		;;
		( * )				# Default case: If no more options then break out of the loop.
		echo "this"
		break
		;;
	esac
	
	echo "stica"
	
	shift
done

# Print the arguments and their values.
echo "Destination directory:\t\"${DBDIR}\"\nDestination DataBase:\t\"${DB}\"\nSource Directory:\t\"${SRCDBDIR}\"\nSource Database:\t\"${SRCDB}\""

# Store the current working directory and move to the Destination Database Directory.
CWD=$(pwd)
cd ${DBDIR}

# Find all the *.ibd files...
echo "Find all the *.ibd files in \"${SRCDBDIR}/${SRCDB}\"..."
IBDS=$(find ${SRCDBDIR}/${SRCDB} -depth 1 -name "*.ibd" -exec basename {} \;)
if [[ "$IBDS" == "" ]] ; then
	echo "Non *.ibd file found. Abort!"
	exit 1
fi
echo "Got the following files to process: {\n$IBDS\n}"

# If there is no directory with the DataBase name, create it.
# if [[ ! -d ${DB} ]] ; then
# 	echo "Creating directory ${DBDIR}/${DB}..."
# 	mkdir ${DB}
# fi

echo "Check if MySQL server is running..."

# Get the PID of 'mysqld' process.
MYSQL_PID=$(pgrep -u root mysqld)
MYSQL_PID_RET=$?
# If no process called 'mysqld' is found, stdout will contain an empty string and return value is 1.
if [[ "$MYSQL_PID" = "" ]] && [[ "$MYSQL_PID_RET" -eq "1" ]]
then
	echo "Start MySQL server with data directory set to \"${DBDIR}\" and log file set to \"${DBDIR}/mysqld.local.err\""
	/usr/local/mysql/bin/mysqld --user=root --datadir=${DBDIR} --log-error=${DBDIR}/mysqld.local.err &
else
	echo "MySQL server is already running with PID = ${MYSQL_PID}."
fi

# Get the port used by MySQL server. --disable-column-names is to remove the headers of
# the columns, -r is to remove escape characters in the output, -s removes the borders of the table.
echo "Get the number of the network port MySQL is listening on..."
PORT=$(mysql --disable-column-names -r -s -e 'SHOW VARIABLES WHERE `Variable_name` = "port";' | awk '{print $2}')
echo "MySQL is listening on port ${PORT}"

# We need to preserve \n and \t for the next operations.
OIFS=${IFS}
IFS=

#mysql_config_editor set --login-path=mysqlfrm_recovery --host=localhost --user=root --password
echo "Extract the SQL table structures from ${SRCDBDIR}/${SRCDB}..."
echo "mysqlfrm --user=root --server=mysqlfrm_recovery:${PORT} ${SRCDBDIR}/${SRCDB} --port=3310"

# SQL=$(mysqlfrm --user=root --basedir=${DBDIR} ${SRCDBDIR}/${SRCDB} --port=3310)
SQL=$(mysqlfrm --user=root --server=mysqlfrm_recovery:${PORT} ${SRCDBDIR}/${SRCDB} --port=3310)
if [ "$?" -eq "1" ]
then
	echo "Something went wrong!"
else
	echo "Successful!!!"
fi

# The computed SQL needs some adjustment:
#	1. Default MySQL 5.7 row format is DYNAMIC therefore we must explicitly set it to COMPACT;
#	2. Each SQL query should end with semicolon ";".
#	3. Furthermore I want to add 'IF NOT EXISTS" to the "CREATE TABLE" sentences.
echo "Prepare and cleanup SQL query..."

# Need to prepare here the command because of the big number of substitutions made by bash.
SED_CMD="s/\\\`${SRCDB}\\\`\.//"

#echo "The command for sed:" $SED_CMD
SQL=$(echo ${SQL} | sed -E -e 's/(^\) +ENGINE=.*$)/\1 ROW_FORMAT=COMPACT;/' | sed -E -e ${SED_CMD})
SQL=$(echo ${SQL} | sed -E -e 's/(CREATE TABLE)/\1 IF NOT EXISTS/')

#echo ${SQL}

# Restore default separator.
IFS=${OIFS}
 
mysql -e "CREATE DATABASE IF NOT EXISTS ${DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
# MYSQL_ERR=$(mysql -e "USE ${DB};" 2>&1 | awk '{ print $1 }')
# if [[ "$MYSQL_ERR" = "ERROR" ]]
# then
# 	echo "${MYSQL_ERR}: DataBase not found!"
# 	exit 1
# else
# 	echo "DataBase ${DB} is active.";
# fi

mysql -e "USE ${DB}; ${SQL}"

for IBD in $IBDS
do
	# Store the default Internal Field Separator, IFS.
	OIFS=$IFS
	
	# Change the IFS to "."
	IFS='.'
	
	# Read the "." separated fields of $IBDS in to an array associated to the variable $FILENAME_PARTS
	read -a FILENAME_PARTS <<< "$IBD"
	
	# File name corresponds to a table name.
	TABLE_NAME=${FILENAME_PARTS[0]}
	
	# File name extension is used to double check.
	FILE_EXT=${FILENAME_PARTS[1]}
	
	# Restore default IFS.
	IFS=OIFS
	
	# Simplification
	SRCIBD="${SRCDBDIR}/${SRCDB}/${IBD}"
	DESTIBD="${DBDIR}/${DB}/${IBD}"

	# This part is paranoid. I'm double checking if the files listed in $IBDS variable have
	# filename extension equal to "ibd".
	if [[ "$FILE_EXT" == "ibd" ]] && [[ -f "${SRCIBD}" ]] ; then
		echo ""
		echo "Computing file ${SRCIBD}..."
		echo ""

		#echo "ALTER TABLE \`${TABLE_NAME}\` ROW_FORMAT=COMPACT;"
		#echo "ALTER TABLE \`${TABLE_NAME}\` ROW_FORMAT=COMPACT;" | mysql --user=root $DB

		echo "ALTER TABLE \`${TABLE_NAME}\` DISCARD TABLESPACE;"
		mysql -e "ALTER TABLE \`${TABLE_NAME}\` DISCARD TABLESPACE;" ${DB}

		# Copy the corresponding ibd file
		echo "Copy \"${SRCIBD}\" to \"${DESTIBD}\"..."
		cp "${SRCIBD}" "${DESTIBD}"

		echo "ALTER TABLE \`${TABLE_NAME}\` IMPORT TABLESPACE;"
		mysql -e "ALTER TABLE \`${TABLE_NAME}\` IMPORT TABLESPACE;" $DB

		echo "------------------------------------------------------------------------------------------------"

	fi
done

cd $CWD
