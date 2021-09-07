#!/bin/bash
# SPDX-License-Identifier: copyleft-next-0.3.1

# Part of the kdevops kernel-ci. This script is in charge of running the
# script which runs the workflow up to the CONFIG_KERNEL_CI_STEADY_STATE_GOAL,
# and then batching out a workflow specific watchdog -- if one was requested --
# (refer to kernel_ci_watchdog_loop()) and finally doing post-processing
# to try to make sense of what the results are (see kernel_ci_post_process())

source ${TOPDIR}/.config
source ${TOPDIR}/scripts/lib.sh

kernel_ci_subject_topic()
{
	if [[ "$CONFIG_KERNEL_CI_ADD_CUSTOM_SUBJECT_TOPIC" != "y" ]]; then
		echo "kernel-ci on $(hostname)"
	elif [[ "$CONFIG_KERNEL_CI_ADD_CUSTOM_SUBJECT_TOPIC_TAG" == "y" ]]; then
		echo "kernel-ci on $(hostname) $CONFIG_KERNEL_CI_SUBJECT_TOPIC $CONFIG_BOOTLINUX_TREE_TAG"
	else
		echo "kernel-ci on $(hostname) $CONFIG_KERNEL_CI_SUBJECT_TOPIC"
	fi
}

RCPT="ignore@test.com"
MAIL_FROM_MOD=""
SSH_TARGET="ignore"
KERNEL_CI_LOOP="${TOPDIR}/scripts/workflows/demos/reboot-limit/run_loop.sh"
SUBJECT_PREFIX="$(kernel_ci_subject_topic): reboot-limit failure on test loop "
KERNEL_CI_LOOP_PID=0
TARGET_HOSTS=$1

kernel_ci_post_process()
{
	if [[ -f $MANUAL_KILL_NOTICE_FILE ]]; then
		exit 1
	fi
	if [[ "$CONFIG_WORKFLOW_KOTD_ENABLE" == "y" ]]; then
		if [[ -f $KOTD_LOG ]]; then
			cat $KOTD_LOG $KERNEL_CI_FAIL_LOG > $KOTD_TMP
			cp $KOTD_TMP $KERNEL_CI_FAIL_LOG
			cp $KOTD_TMP $KERNEL_CI_DIFF_LOG
			rm -f $KOTD_TMP
		fi
	fi
	if [[ -f $KERNEL_CI_WATCHDOG_FAIL_LOG ]]; then
		cat $KERNEL_CI_WATCHDOG_FAIL_LOG >> $KERNEL_CI_FAIL_LOG
		cat $KERNEL_CI_WATCHDOG_FAIL_LOG >> $KERNEL_CI_DIFF_LOG
	fi

	if [[ ! -s $KERNEL_CI_LOGTIME_FULL ]]; then
		echo "-------------------------------------------" >> $KERNEL_CI_FAIL_LOG
		echo "Full run time of kernel-ci loop:" >> $KERNEL_CI_FAIL_LOG
		cat $KERNEL_CI_LOGTIME_FULL >> $KERNEL_CI_FAIL_LOG

		echo "-------------------------------------------" >> $KERNEL_CI_DIFF_LOG
		echo "Full run time of kernel-ci loop:" >> $KERNEL_CI_DIFF_LOG
		cat $KERNEL_CI_LOGTIME_FULL >> $KERNEL_CI_DIFF_LOG
	fi

	if [[ "$CONFIG_KERNEL_CI_EMAIL_REPORT" != "y" ]]; then
		if [[ -f $KERNEL_CI_FAIL_FILE ]]; then
			FAIL_LOOP="$(cat $KERNEL_CI_FAIL_FILE)"
			SUBJECT="$SUBJECT_PREFIX $FAIL_LOOP"
			echo $SUBJECT
			if [[ ! -s $KERNEL_CI_LOGTIME_FULL ]]; then
				echo "Full run time of kernel-ci loop:"
				cat $KERNEL_CI_LOGTIME_FULL
			fi
			exit 1
		elif [[ -f $KERNEL_CI_OK_FILE ]]; then
			LOOP_COUNT=$(cat $KERNEL_CI_OK_FILE)
			SUBJECT="$(kernel_ci_subject_topic) reboot-limit never failed after $LOOP_COUNT test loops"
			echo $SUBJECT
			if [[ ! -s $KERNEL_CI_LOGTIME_FULL ]]; then
				echo "Full run time of kernel-ci loop:"
				cat $KERNEL_CI_LOGTIME_FULL
			fi
			exit 0
		fi
	fi

	if [[ -f $KERNEL_CI_FAIL_FILE ]]; then
		FAIL_LOOP="$(cat $KERNEL_CI_FAIL_FILE)"
		SUBJECT="$SUBJECT_PREFIX $FAIL_LOOP"

		if [[  -f $KERNEL_CI_WATCHDOG_FAIL_LOG ]]; then
			SUBJECT="$SUBJECT and watchdog picked up a hang"
		fi

		if [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_LOCAL" == "y" ]]; then
			cat $KERNEL_CI_DIFF_LOG | mail -s "$SUBJECT" $MAIL_FROM_MOD $RCPT
		elif [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_SSH" == "y" ]]; then
			cat $KERNEL_CI_DIFF_LOG | ssh $SSH_TARGET 'mail -s "'$SUBJECT'"' $MAIL_FROM_MOD $RCPT
		fi
		echo $SUBJECT
		exit 1
	elif [[ -f $KERNEL_CI_OK_FILE ]]; then
		LOOP_COUNT=$(cat $KERNEL_CI_OK_FILE)
		SUBJECT="$(kernel_ci_subject_topic): reboot-limit test achieved steady-state goal of $LOOP_COUNT test loops!"
		GOAL="$CONFIG_KERNEL_CI_STEADY_STATE_GOAL"
		if [[ "$CONFIG_KERNEL_CI_ENABLE_STEADY_STATE" == "y" &&
		      "$LOOP_COUNT" -lt "$CONFIG_KERNEL_CI_STEADY_STATE_GOAL" ]]; then
			SUBJECT="$(kernel_ci_subject_topic): reboot-limit test bailed out on loop $LOOP_COUNT before steady-state goal of $GOAL!"
                fi
		if [[  -f $KERNEL_CI_WATCHDOG_FAIL_LOG ]]; then
			SUBJECT="$(kernel_ci_subject_topic): reboot-limit test detected a hang after $LOOP_COUNT test loops"
		fi

		if [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_LOCAL" == "y" ]]; then
			cat $KERNEL_CI_FAIL_LOG | mail -s "$SUBJECT" $MAIL_FROM_MOD $RCPT
		elif [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_SSH" == "y" ]]; then
			cat $KERNEL_CI_FAIL_LOG | ssh $SSH_TARGET 'mail -s "'$SUBJECT'"' $MAIL_FROM_MOD $RCPT
		fi

		echo "$SUBJECT"

		if [[  -f $KERNEL_CI_WATCHDOG_FAIL_LOG ]]; then
			exit 1
		else
			exit 0
		fi
	elif [[  -f $KERNEL_CI_WATCHDOG_FAIL_LOG ]]; then
		SUBJECT="$(kernel_ci_subject_topic): reboot-limit test failed due to a hung task on the first loop"
		cat $KERNEL_CI_WATCHDOG_FAIL_LOG
		if [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_LOCAL" == "y" ]]; then
			cat $KERNEL_CI_DIFF_LOG | mail -s "$SUBJECT" $MAIL_FROM_MOD $RCPT
		elif [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_SSH" == "y" ]]; then
			cat $KERNEL_CI_DIFF_LOG | ssh $SSH_TARGET 'mail -s "'$SUBJECT'"' $MAIL_FROM_MOD $RCPT
		fi
		exit 1
	else
		echo "The kernel-ci loop will create the file $KERNEL_CI_FAIL_FILE if"
		echo "we completed with failure, while the $KERNEL_CI_OK_FILE would be"
		echo "created if no failure was found. We did not find either file."
		echo "This is an unexpected situation."

		SUBJECT="$(kernel_ci_subject_topic): reboot-limit test exited in an unexpection situation"
		if [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_LOCAL" == "y" ]]; then
			cat $KERNEL_CI_LOGTIME_FULL | mail -s "$SUBJECT" $MAIL_FROM_MOD $RCPT
		elif [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_SSH" == "y" ]]; then
			cat $KERNEL_CI_LOGTIME_FULL | ssh $SSH_TARGET 'mail -s "'$SUBJECT'"' $MAIL_FROM_MOD $RCPT
		fi
		exit 1
	fi
}

kernel_ci_watchdog_loop()
{
	echo starting watchdog loop >> $KERNEL_CI_WATCHDOG_LOG
	WATCHDOG_SLEEP_TIME=$CONFIG_REBOOT_LIMIT_WATCHDOG_CHECK_TIME
	while true; do
		if [[ -f $MANUAL_KILL_NOTICE_FILE ]]; then
			exit 1
		fi
		HUNG_FOUND="False"
		TIMEOUT_FOUND="False"
		echo watchdog loop work >> $KERNEL_CI_WATCHDOG_LOG
		rm -f $KERNEL_CI_WATCHDOG_FAIL_LOG $KERNEL_CI_WATCHDOG_HUNG $KERNEL_CI_WATCHDOG_TIMEOUT

		if [[ ! -f $REBOOT_LIMIT_STARTED_FILE ]]; then
			if [[ ! -d /proc/$KERNEL_CI_LOOP_PID ]]; then
				# If $KERNEL_CI_FAIL_FILE doesn't exist and we have the $KERNEL_CI_OK_FILE file
				# we've reached steady state, so don't send extra information to stdout to
				# avoid confusing the user.
				if [[ -f $KERNEL_CI_FAIL_FILE || ! -f $KERNEL_CI_OK_FILE ]]; then
					echo "PID ($KERNEL_CI_LOOP_PID) for $KERNEL_CI_LOOP process no longer found, bailing watchdog"
				fi
				break
			fi
			echo watchdog does not yet see start file $REBOOT_LIMIT_STARTED_FILE so waiting $WATCHDOG_SLEEP_TIME seconds >> $KERNEL_CI_WATCHDOG_LOG
			sleep $WATCHDOG_SLEEP_TIME
			continue
		fi

		if [[ ! -d /proc/$KERNEL_CI_LOOP_PID ]]; then
			echo "Test not running" > $KERNEL_CI_WATCHDOG_RESULTS_NEW
			cp $KERNEL_CI_WATCHDOG_RESULTS_NEW $KERNEL_CI_WATCHDOG_RESULTS
			break
		fi

		# XXX: here we can develop some sort of custom watchdog for
		# the reboot-limit test. Refer to the fstest watchdog for an example
		# of something elaborate.

		sleep $WATCHDOG_SLEEP_TIME
	done
}

rm -f ${TOPDIR}/.kernel-ci.*
rm -f $REBOOT_LIMIT_STARTED_FILE

if [[ "$CONFIG_KERNEL_CI_EMAIL_REPORT" == "y" ]]; then
	RCPT="$CONFIG_KERNEL_CI_EMAIL_RCPT"
	if [[ "$CONFIG_KERNEL_CI_EMAIL_METHOD_SSH" == "y" ]]; then
		SSH_TARGET="$CONFIG_KERNEL_CI_EMAIL_SSH_HOST"
	fi
fi

if [[ "$CONFIG_REBOOT_LIMIT_WATCHDOG" == "y" ]]; then
	rm -f $KERNEL_CI_WATCHDOG_RESULTS_NEW $KERNEL_CI_WATCHDOG_RESULTS
fi

/usr/bin/time -f %E -o $KERNEL_CI_LOGTIME_FULL $KERNEL_CI_LOOP &
KERNEL_CI_LOOP_PID=$!

if [[ "$CONFIG_REBOOT_LIMIT_WATCHDOG" != "y" ]]; then
	echo Skipping watchdog and just waiting for kernel-ci PID to complete >> $KERNEL_CI_WATCHDOG_LOG
	wait
else
	echo Kicking off watchdog loop >> $KERNEL_CI_WATCHDOG_LOG
	kernel_ci_watchdog_loop
	echo Completed watchdog loop >> $KERNEL_CI_WATCHDOG_LOG
fi

kernel_ci_post_process
