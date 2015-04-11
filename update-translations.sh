#!/bin/bash -xe

# This script is run by the jenkins 'update-translations' job, to
# 1) download up-to-date translations from crowdin
# 2) sanity-check the results and check them in
# 3) upload the latest all.pot to crowdin


SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd -P )"
WORKSPACE_ROOT=`pwd -P`
source "${SCRIPT_DIR}/build.lib"
ensure_virtualenv
decrypt_secrets_py_and_add_to_pythonpath

( cd "$WEBSITE_ROOT" && "$MAKE" install_deps )


# After downloading a lang.po file from crowdin, splits it up like we want.
# $1: the language to split (eg 'en-PT').
split_po() {
    # Remove the old .rest.po and .datastore.po files.
    rm -f "intl/translations/pofiles/$1.rest.po"
    rm -f "intl/translations/pofiles/$1.datastore.po"

    # Split the po-file into datastore only strings and all other strings.
    tools/split_po_files.py "intl/translations/pofiles/$1.po"

    # github has a limit of 100M per file.  We split up the .po files to
    # stay under the limit.  For consistency with files that don't need
    # to be split up at all (and to make all_locales_for_mo() happy), we
    # don't give the first chunk an extension but do for subsequent chunks.
    # (Same as how /var/log/syslog works.)
    for p in intl/translations/pofiles/"$1".*.po; do
        split --suffix-length=1 --line-bytes=95M --numeric-suffixes "$p" "$p."
        mv -f "$p.0" "$p"
    done
}


# --- The actual work:

# This lets us commit messages without a test plan
export FORCE_COMMIT=1

echo "Checking status of dropbox"

# dropbox.py doesn't like it when the directory is a symlink
DATA_DIR=`readlink -f /mnt/dropbox/Dropbox/webapp-i18n-data`

# Start dropbox service if it is not running
! HOME=/mnt/dropbox dropbox.py running || HOME=/mnt/dropbox dropbox.py start

busy_wait_on_dropbox "$DATA_DIR"/upload_to_crowdin
busy_wait_on_dropbox "$DATA_DIR"/download_from_crowdin
busy_wait_on_dropbox "$DATA_DIR"/crowdin_data.pickle

echo "Dropbox folders are ready and fully synched"

echo "Updating the version of intl/translations that stores data as bigfiles"
safe_sync_to "git@github.com:Khan/webapp-i18n-bigfile" master
BIGFILE_REPO_DIR="$WORKSPACE_ROOT"/webapp-i18n-bigfile

cd "$WEBSITE_ROOT"

echo "Updating the webapp repo."
safe_pull .
# We also make sure the translations sub-repo is up to date.
safe_pull intl/translations

for lang in `tools/list_candidate_active_languages.py` ; do
    echo "Downloading the current translations for $lang from crowdin."
    deploy/download_i18n.py -v -s "$DATA_DIR"/download_from_crowdin/ \
       --lint_log_file "$DATA_DIR"/download_from_crowdin/"$lang"_lint.pickle \
       --use_temps_for_linting \
       --english-version-dir="$DATA_DIR"/upload_to_crowdin \
       --crowdin-data-filename="$DATA_DIR"/crowdin_data.pickle \
       --send-lint-reports \
       --export \
       $lang
done

echo "Creating a new, up-to-date all.pot."
# Both handlebars.babel and shared_jinja.babel look for popular_urls in /tmp,
# but we also want to keep a version in source control for debugging purposes.
# TODO(csilvers): uncomment once we get popular_pages up and using bigquery.
#tools/popular_pages.py --limit 10000 > "$DATA_DIR"/popular_urls
cp -f "$DATA_DIR"/popular_urls /tmp/
# By removing genfiles/extracted_strings/en/intl/datastore.pot.pickle,
# we force compile_all_pot to re-fetch nltext datastore info from prod.
rm -f genfiles/extracted_strings/en/intl/datastore.pot.pickle
kake/build_prod_main.py -v3 pot
# This is where build_prod_main.py puts the output all.pot
ALL_POT="$PWD"/genfiles/translations/all.pot.txt_for_debugging

echo "Sanity check: will fail if the new all.pot is missing stuff."
[ `wc -l < "$ALL_POT"` -gt 100000 ]
grep -q 'intl/datastore:1' "$ALL_POT"

echo "Translating fake languages."
"$MAKE" i18n_mo

echo "Splitting .po files"
# Just look at the lang.po files, ignoring lang.rest.po/etc.
langs=`ls -1 intl/translations/pofiles | sed -n 's/^\([^.]*\)\.po$/\1/p'`
for lang in $langs; do
    split_po "$lang"
done

echo "Done creating .po files:"
ls -l intl/translations/pofiles/

cp "$ALL_POT" "$DATA_DIR"/all.pot

echo "Uploading the new all.pot to crowdin."
deploy/upload_i18n.py -v --save-temps="$DATA_DIR"/upload_to_crowdin/ \
   --use-temps-to-skip \
   --crowdin-data-filename="$DATA_DIR"/crowdin_data.pickle \
   --popular-urls="$DATA_DIR"/popular_urls \
   --pot-filename="$ALL_POT"

echo "Downloading the new en-PT jipt tags from crowdin for translate.ka.org."
deploy/download_i18n.py -v -s "$DATA_DIR"/download_from_crowdin/ \
    --english-version-dir="$DATA_DIR"/upload_to_crowdin \
    --crowdin-data-filename="$DATA_DIR"/crowdin_data.pickle \
    --export \
    --nolint \
    en-pt

# Split up en-PT as well.
split_po "en-pt"

echo "Checking in crowdin_stringids.pickle and pofiles/*.po"
safe_commit_and_push intl/translations \
   -m "Automatic update of crowdin .po files and crowdin_stringids.pickle" \
   -m "(at webapp commit `git rev-parse HEAD`)"

echo "Checking in a copy of those files to the bigfile repo as well"
rsync -av intl/translations/* "$BIGFILE_REPO_DIR"/
safe_commit_and_push "$BIGFILE_REPO_DIR" \
   -m "Automatic update of crowdin .po files and crowdin_stringids.pickle" \
   -m "(at webapp commit `git rev-parse HEAD`)"

echo "DONE"
