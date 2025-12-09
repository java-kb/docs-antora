#!/bin/sh
# from https://github.com/vshn/antora-preview
# A wrapper to run subprocesses in the background but forward SIGTERM/SIGINT to them
# Adapted from https://medium.com/@manish_demblani/docker-container-uncaught-kill-signal-d5ed22698293
signalListener() {
    "$@" &
    pid="$!"
    trap "caddy stop; echo 'Stopping PID $pid'; kill -SIGTERM $pid" SIGINT SIGTERM

    # A signal emitted while waiting will make the wait command return code > 128
    # Let's wrap it in a loop that doesn't end before the process is indeed stopped
    while kill -0 $pid > /dev/null 2>&1; do
	# Only wait for the specific child pid we extracted in this function,
	# as otherwise we wait forever for the ruby subprocess started by
	# `guard` which is apparently not properly terminated when sending
	# `SIGTERM` to `guard`.
        wait $pid
    done
}

# for i in "$@"
# do
# case $i in
#     -s=*|--style=*)
#     ANTORA_STYLE="${i#*=}"

#     ;;
#     -a=*|--antora=*)
#     ANTORA_PATH="${i#*=}"
#     ;;
#     *)
#         echo ""
#         echo "Antora Documentation Previewer"
#         echo ""
#         echo "This command builds an Antora documentation website locally and launches a web server on port 2020 to browse the documentation."
#         echo ""
#         echo "Arguments:"
#         echo "    --style=STYLE / -s=STYLE:"
#         echo "           Antora UI Bundle to use to render the documentation."
#         echo "           Valid values: 'vshn', 'appuio', 'syn', 'k8up', 'antora'."
#         echo "           Default value: 'vshn'"
#         echo ""
#         echo "    -a=PATH / --antora=PATH:"
#         echo "           Path to the subfolder."
#         echo "           Default: 'docs'"
#         echo ""
#         echo "Examples:"
#         echo "    antora-preview --style=appuio --antora=src"
#         echo ""
#         echo "GitHub project: https://github.com/vshn/antora-preview"
#         echo ""
#         exit 0
#     ;;
# esac
# done

# ANTORA_STYLE=${ANTORA_STYLE:-vshn}
# ANTORA_PATH=${ANTORA_PATH:-docs}

# ANTORA_FILE=/preview/antora/$ANTORA_PATH/antora.yml
# if [ ! -f "$ANTORA_FILE" ]; then
# 	echo "Cannot find Antora file '$ANTORA_FILE'"
# 	exit 1
# fi

# ANTORA_BUNDLE=/preview/bundles/$ANTORA_STYLE.zip
# if [ ! -f "$ANTORA_BUNDLE" ]; then
# 	echo "Cannot find Antora UI Bundle '$ANTORA_BUNDLE'"
# 	exit 1
# fi

# Read component name from antora.yml
# COMPONENT=$(yq eval '.name' /preview/antora/"$ANTORA_PATH"/antora.yml)
# TITLE=$(yq eval '.title' /preview/antora/"$ANTORA_PATH"/antora.yml)
# echo "===> Generating Antora documentation for component '$TITLE' in file '$ANTORA_FILE'"
# echo "===> Using style: $ANTORA_STYLE"
# echo ""

# # Overwrite values in Antora playbook
# yq eval --inplace '.site.start_page="'"$COMPONENT"'::index.adoc"' /preview/playbook.yml
# yq eval --inplace '.site.title="'"$TITLE"'"' /preview/playbook.yml
# yq eval --inplace '.content.sources[0].start_path="'"$ANTORA_PATH"'"' /preview/playbook.yml
# yq eval --inplace '.ui.bundle.url="'"$ANTORA_BUNDLE"'"' /preview/playbook.yml

# # Generate website
npx antora antora-playbook.yml

# Launch Caddy web server
echo ""
echo " _____________________________________________________________________"
echo "|                                                                     |"
echo "| Open http://localhost:2020 in your browser to see the documentation |"
echo "|                                                                     |"
echo "| IMPORTANT! LIVE RELOADING REQUIRES A BROWSER PLUGIN!                |"
echo "| More info here: https://github.com/vshn/antora-preview#livereload   |"
echo "|_____________________________________________________________________|"
echo ""
caddy start
# npx http-server build/site -s -c-1

# Watcher: prefer inotifywait (from inotify-tools) for efficient file event
# notifications. If not available, fall back to a simple polling loop that
# checks file checksums. On change, rebuild the site with Antora.
watch_loop() {
    if command -v inotifywait >/dev/null 2>&1; then
        echo "Using inotifywait for file watching (install inotify-tools if missing)."

        rebuild_component() {
            target="$1"
            # If playbook or UI changed, do a full build
            case "$target" in
                */antora-playbook.yml|antora-playbook.yml|ui/*|ui)
                    echo "Playbook/UI change detected — doing full build"
                    npx antora antora-playbook.yml
                    return
                    ;;
            esac

            # Determine top-level component to build. Antora requires a
            # component descriptor file (`antora.yml`) in the component
            # root. If none exists, do a full build.
            if echo "$target" | grep -q "^modules/"; then
                module=$(echo "$target" | sed -n 's#modules/\([^/]*\).*#\1#p')
                start_path="modules/$module"
            elif echo "$target" | grep -q "^01-core"; then
                start_path="01-core"
            else
                # Unknown path -> full build
                echo "Unknown change path '$target' — doing full build"
                npx antora antora-playbook.yml
                return
            fi

            # If the detected start_path is not a component (missing antora.yml)
            # Antora cannot do a single-component build there — fall back to
            # a full build.
            if [ ! -f "$start_path/antora.yml" ]; then
                echo "No component descriptor at '$start_path/antora.yml' — doing full build"
                npx antora antora-playbook.yml
                return
            fi

            echo "Incremental build for start_path=$start_path"

            # Heuristic: if the changed file contains cross-component xrefs
            # (e.g. "other-component::page.adoc" or xref paths outside the
            # current module), Antora will not resolve them during a
            # single-component build. Detect such patterns and fall back to
            # a full build to avoid missing-xref errors.
            if [ -f "$target" ]; then
                # extract the module name (last path component of start_path)
                current_module=$(basename "$start_path")
                # look for component::target patterns
                if grep -Eo "[A-Za-z0-9._-]+::[^"]+" "$target" | grep -v "^${current_module}::" >/dev/null 2>&1; then
                    echo "Detected cross-component xref in '$target' — doing full build"
                    npx antora antora-playbook.yml
                    return
                fi
                # look for xref: some/path.adoc[] style referencing other top-level dirs
                if grep -Eo "xref:[[:alnum:]-]+/[^"]+" "$target" | grep -v "^xref:${current_module}/" >/dev/null 2>&1; then
                    echo "Detected cross-module xref path in '$target' — doing full build"
                    npx antora antora-playbook.yml
                    return
                fi
            fi

            TMP_PLAYBOOK=$(mktemp ./antora-playbook.XXXXXX.yml)
            WORKSPACE_DIR=$(pwd)

            # Copy the original playbook and update (or insert) the
            # first content.sources[0].start_path so Antora keeps its required
            # top-level `antora` configuration (generator, extensions, etc.).
            cp antora-playbook.yml "$TMP_PLAYBOOK"

            # If a start_path already exists, replace the first occurrence.
            if grep -q '^[[:space:]]*start_path:' "$TMP_PLAYBOOK"; then
                awk -v sp="$start_path" 'BEGIN{replaced=0}
                /^[[:space:]]*start_path:/ {
                    if(!replaced){ print gensub(/^[[:space:]]*start_path:.*/, "    start_path: " sp, 1); replaced=1; next }
                }
                { print }
                END{ if(!replaced) exit 0 }' "$TMP_PLAYBOOK" > "$TMP_PLAYBOOK.tmp" && mv "$TMP_PLAYBOOK.tmp" "$TMP_PLAYBOOK"
            else
                # Insert start_path under the first "-" entry of content.sources
                awk -v sp="$start_path" 'BEGIN{in_content=0; in_sources=0; inserted=0}
                /^[[:space:]]*content:/ { print; in_content=1; next }
                in_content && /^[[:space:]]*sources:/ { print; in_sources=1; next }
                in_sources && match($0,/^([[:space:]]*)-/,a) && !inserted {
                    print; print a[1] "  start_path: " sp; inserted=1; in_sources=0; in_content=0; next
                }
                { print }
                END{ if(!inserted){ # fallback: append a minimal content.sources block
                    print "content:"; print "  sources:"; print "  - url: ."; print "    start_path: " sp }
                }' "$TMP_PLAYBOOK" > "$TMP_PLAYBOOK.tmp" && mv "$TMP_PLAYBOOK.tmp" "$TMP_PLAYBOOK"
            fi

            # Keep the temporary playbook inside the workspace so relative
            # paths like "./ui" continue to resolve correctly (Antora
            # resolves supplemental_files relative to the playbook).
            echo "Using adjusted playbook: $TMP_PLAYBOOK"
            npx antora "$TMP_PLAYBOOK"
            rm -f "$TMP_PLAYBOOK"
        }

        # Use inotifywait in monitor mode and handle each event line-by-line
        inotifywait -r -m -e modify,create,delete,move --format '%w%f' modules 01-core antora-playbook.yml ui 2>/dev/null |
        while read -r changed; do
            echo "Detected change: $changed"
            rebuild_component "$changed"
        done
    else
        echo "inotifywait not found — using polling fallback. For better performance, install inotify-tools."
        LAST_SUM=""
        while true; do
            NOW_SUM=$(find modules 01-core ui antora-playbook.yml -type f -print0 2>/dev/null | sort -z | xargs -0 sha1sum 2>/dev/null | sha1sum 2>/dev/null || true)
            if [ "${LAST_SUM}" != "${NOW_SUM}" ]; then
                echo "Change detected (polling), determining incremental target..."
                # Simple heuristic: if playbook or ui changed, full build
                if ! find ui antora-playbook.yml -newermt "-2s" | grep -q . 2>/dev/null; then
                    # Try to detect which module changed by comparing timestamps
                    CHANGED_PATH=$(find modules 01-core -type f -newermt "-2s" -print 2>/dev/null | head -n 1 || true)
                else
                    CHANGED_PATH=antora-playbook.yml
                fi
                if [ -n "$CHANGED_PATH" ]; then
                    echo "Polling detected change: $CHANGED_PATH"
                    rebuild_component "$CHANGED_PATH"
                else
                    echo "Polling: couldn't determine specific change, doing full build"
                    npx antora antora-playbook.yml
                fi
                LAST_SUM="${NOW_SUM}"
            fi
            sleep 1
        done
    fi
}

# Run the watcher under signalListener so SIGINT/SIGTERM are forwarded
signalListener watch_loop