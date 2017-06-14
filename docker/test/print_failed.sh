#!/bin/bash

let max_print_failed=50

function usage ()
{
     echo "Usage: $0 [-x <xml output path>] [-n show count] <result path>"
}

while getopts "x:n:" opt; do
     case $opt in
     x)
         xml_output="$OPTARG"
         [ ! -d "$xml_output" ] && mkdir -p "$xml_output"
         ;;
     n)
         max_print_failed=$OPTARG
         ;;
     *)
         usage
         exit 1
         ;;
     esac
done
shift $(($OPTIND - 1))

if [ $# -lt 1 ]; then
  usage
  exit 1
fi
result_path=$1
if [ ! -d $result_path ]; then
  echo "Result path '$result_path' does not exist."
  usage
  exit 1
fi

let ncount=0

failed_list=$(find $result_path -name summary_info | xargs -n1 grep -hw nok | awk -F: '{print $1}')
if [ -z "$failed_list" ]; then
  nfailed=0
else
  nfailed=$(echo "$failed_list" | wc -l)
fi
echo ""
if [ $max_print_failed -ne 0 -a $nfailed -gt $max_print_failed ]; then
  echo "** There are too many failed ($nfailed) Testcases on this test."
  echo "** It will print details of only $max_print_failed failed Testcases."
elif [ $nfailed -gt 0 ]; then
  echo "** There are $nfailed failed Testcases on this test."
  echo "** It will print details of $nfailed failed Testcases."
fi
echo ""

for f in $failed_list; do
  casefile=$f
  answerfile=${f/\/cases\//\/answers\/}
  answerfile=${answerfile/%.sql/.answer}
  resultfile=${f/%.sql/.result}

  diffdir=$(mktemp -d)
  #egrep -v '^--|^$' $casefile | csplit -n0 -sz -f $diffdir/case - '/;/' '{*}'
  egrep -v '^--|^$|^autocommit' $casefile | awk -v outdir="$diffdir" '{printf "%s;\n", $0 > outdir"/case"NR-1}' RS=';[ \t\r]*\n'
  nq=$(ls $diffdir/case* | wc -l)
  csplit -n0 -sz -f $diffdir/answer $answerfile '/===================================================/' '{*}'
  na=$(ls $diffdir/answer* | wc -l)
  csplit -n0 -sz -f $diffdir/result $resultfile '/===================================================/' '{*}'
  nr=$(ls $diffdir/result* | wc -l)

  echo "-------------------------------------------------------------------------------------------------------------------"
  echo "** Testcase : ${casefile##*$HOME/} (total: $nq queries)"
  echo "** Expected : ${answerfile##*$HOME/}"
  echo "** Actual   : ${resultfile##*$HOME/}"
  echo "-------------------------------------------------------------------------------------------------------------------"
  [ $nq -eq $na -a $nq -eq $nr ] || { echo "error ($nq != $na != $nr)"; exit 1; }
  (( ncount++ ))
  for i in $(awk "BEGIN { for (i=0; i<$nq; i++) printf(\"%d \", i) }"); do
    if $(cmp -s $diffdir/answer$i $diffdir/result$i) ; then
      continue
    else
      echo "** Failed query #$((i+1)) (in failed Testcase #$ncount of $nfailed: $(basename $casefile))"
      cat $diffdir/case$i
      echo "-------------------------------------------------------------------------------------------------------------------"
      diff -u $diffdir/answer$i $diffdir/result$i
    fi
  done
  rm -rf $diffdir

  if [ $max_print_failed -ne 0 -a $ncount -ge $max_print_failed ]; then
    break
  fi
done

echo ""
if [ $max_print_failed -ne 0 -a $nfailed -gt $max_print_failed ]; then
  echo "-------------------------------------------------------------------------------------------------------------------"
  echo "** More than $max_print_failed failed Testcases are omitted. (There are $nfailed failed Testcases on this test)"
fi
echo ""

if [ -n "$xml_output" ]; then
  summary_xml_list=$(find $result_path -name summary.xml)
  for f in $summary_xml_list; do
    target=$(dirname ${f##*schedule_})
    target=${target%_*}
    cat << "_EOL" | xsltproc --stringparam target "${target}" - $f > "$xml_output/${target}.xml"
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
 <xsl:output indent="yes"/>
 <xsl:template match="results">
   <testsuites>
     <testsuite name="{$target}" tests="{count(scenario)}" failures="{count(scenario/result[contains(.,'fail')])}">
       <xsl:apply-templates select="scenario"/>
     </testsuite>
   </testsuites>
 </xsl:template>
 <xsl:template match="scenario">
   <testcase classname="{$target}" name="{case}" time="{elapsetime div 1000}">
      <xsl:if test="result='fail'">
        <failure message="failed"/>
      </xsl:if>
   </testcase>
 </xsl:template>
</xsl:stylesheet>
_EOL
  done
fi

if [ $nfailed -gt 0 ]; then
  echo "** There are $nfailed failed Testcases on this test."
  echo "** All failed Testcases are listed below:"
  for f in $failed_list ; do
    echo " - ${f##*$HOME/}"
  done
  echo "** $nfailed cases are failed."
  exit $nfailed
else
  echo "** All Tests are passed"
fi
