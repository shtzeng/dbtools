#!/bin/bash

# file path
GIT="/usr/bin/git"
JQ="/usr/bin/jq"
LS="/bin/ls"
MKDIR="/bin/mkdir"
MYSQLDUMP="/usr/bin/mysqldump"
PT_FIND="/usr/bin/pt-find"
PWD="/bin/pwd"
RM="/bin/rm"
RSYNC="/usr/bin/rsync"
SED="/bin/sed"
TOUCH="/bin/touch"

# DATA Paths
BASE_DIR=`$PWD`
SCHEMA_DIR="$BASE_DIR/schema/"
SECRETS=""
TMP_DIR="$BASE_DIR/tmp/"

function lock {
    if [[ ! -e "$TMP_DIR/.runlock" ]]; then
        p "===>>> Flush Old Data Now..."
        $RM -rf $TMP_DIR/*
        p "===>>> Flush Finished"
        $TOUCH "$TMP_DIR/.runlock"
    else
        p "===>>> Program Already Running, skip"
        exit -1
    fi
}

function p {
    if [[ ! -n $VAR_QUIET ]]; then
        echo $1
    fi
}

function unlock {
    if [[ -e "$TMP_DIR/.runlock" ]]; then
        p "===>>> Flush TMP Data Now..."
        $RM -rf $TMP_DIR/*
        $RM -rf $TMP_DIR/.runlock
        p "===>>> Flush Finished"
    else
        p "===>>> My Lock loose..... Why ?"
        exit -1
    fi
}

function usage {
    version
    echo ''
    echo 'Usage:'
    echo "Common flags: [--quiet] --secret=DB_SECRET_PATH"
    echo "--help show this manual"
    echo "--quiet No stdout"
    echo "--secret Path to database credentials, json format can follow example/db.json"
    echo "--update-schema Sync schema with git"
    echo "--version display the version number"
    exit 0
}

function version {
    VERSION=`head -n 1 Version.txt`
    echo "===>>> $VERSION"
}

# Get Variables
for VAR in $@
do
    case $VAR in
    --help)     usage 0 ;;
    --quiet)    VAR_QUIET=var_quiet ;;
    --secret=*) SECRETS=${VAR#--secret=} ;;
    --update-schema)    VAR_UPDATE_SCHEMA=var_update_schema ;;
    --version)  version ; exit 0 ;;
    *)          NEWOPTS="$NEWOPTS $VAR" ;;
    esac
done

set -- $NEWOPTS
unset VAR NEWOPTS

#####################################################
#   Main Program                                    #
#####################################################

# First, require a lock for running
lock

# Get DB List
if [[ -d $SECRETS ]]; then
    DBS=`$LS $SECRETS`
else
    p "===>>> SECRETS is not a directory"
    unlock
    exit -1
fi

for DB in $DBS
do
    # check it is db secret
    if [[ ! -f "$SECRETS/$DB/db.json" ]]; then
        continue
    fi

    DB_HOSTNAME=`jq -r .[].reader.params.host $SECRETS/$DB/db.json`
    DB_USER=`jq -r .[].reader.params.username $SECRETS/$DB/db.json`
    DB_PASSWORD=`jq -r .[].reader.params.password $SECRETS/$DB/db.json`
    DB_DATABASE=`jq -r .[].reader.params.dbname $SECRETS/$DB/db.json`
    
    # Create Database folder
    p "==>> Create the Database $DB_DATABASE"
    $MKDIR "$TMP_DIR/$DB_DATABASE"

    # Fetch Schema
    TABLES=`echo | $PT_FIND --charset utf8 --noquote --noversion-check --host $DB_HOSTNAME --user $DB_USER --password $DB_PASSWORD --dblike $DB_DATABASE --printf "%N "`

    for TABLE in $TABLES
    do
        p "=> Fetch the table schema $TABLE"
        $MYSQLDUMP --compact --skip-set-charset --no-data --single-transaction -h $DB_HOSTNAME -u $DB_USER -p$DB_PASSWORD $DB_DATABASE $TABLE > $TMP_DIR/$DB_DATABASE/$TABLE.sql

        # Remove Empty Line
        $SED -i '/^$/d' $TMP_DIR/$DB_DATABASE/$TABLE.sql
        # Remove Comment Line
        $SED -i '/^--/d' $TMP_DIR/$DB_DATABASE/$TABLE.sql
        # Remove Funciton Line
        $SED -i '/\/\*\!.*\*\/\;/d' $TMP_DIR/$DB_DATABASE/$TABLE.sql
        # Remove Auto_Increment
        $SED -i 's/ AUTO_INCREMENT=[0-9]* / /g' $TMP_DIR/$DB_DATABASE/$TABLE.sql
    done

    # Sync To Schema Dir
    p "===>>> Sync Data"
    $RSYNC -a --delete $TMP_DIR/$DB_DATABASE $SCHEMA_DIR/
done

# Finally, release lock
unlock

#####################################################
# Update Schema                                     #
#####################################################
if [[ -n $VAR_UPDATE_SCHEMA ]]; then
    # Add all changes
    cd schema
    $GIT add -A

    # Generate change comment
    CHANGE_LISTS=`$GIT status -s`

    declare -A CHANGES

    IFS=$'\n'
    for CHANGE in $CHANGE_LISTS
    do
        IFS=$' ' read TAG TAG_DETAIL <<< $CHANGE

        if [[ -n ${CHANGES[$TAG]} ]]; then
            CHANGES[$TAG]="${CHANGES[$TAG]}, $TAG_DETAIL"
        else
            CHANGES[$TAG]="$TAG_DETAIL"
        fi
    done

    declare -A GIT_SHORT_TAG
    GIT_SHORT_TAG["A"]="Add"
    GIT_SHORT_TAG["M"]="Modify"
    GIT_SHORT_TAG["D"]="Delete"
    GIT_SHORT_TAG["R"]="Peplace"
    GIT_COMMENT=""

    for TAG in ${!CHANGES[@]}
    do
        if [[ -n $GIT_COMMENT ]]; then
            GIT_COMMENT="$GIT_COMMENT\n${GIT_SHORT_TAG[$TAG]} ${CHANGES[$TAG]}"
        else
            GIT_COMMENT="${GIT_SHORT_TAG[$TAG]} ${CHANGES[$TAG]}"
        fi
    done

    p "===>>> Update Data"
    if [[ -n $GIT_COMMENT ]]; then
        p "Run: git commit -a -m \"$GIT_COMMENT\""
        $GIT commit -a -m "$GIT_COMMENT"
        $GIT push
    else
        p "==>> Already Up-to-date!"
    fi
fi
