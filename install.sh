#!/bin/bash

# Usage: install.sh --python|--ruby [<branch>]
#
# Branch is "master" if unspecified.

set -e

LANGUAGE=$1
BRANCH=${2:-master}

fromStr=

if [ -n "$1" ]; then fromStr=" from $BRANCH"; fi

echo "= Installing the Datawire MDK${fromStr}"

PYVER=$(python -c "import platform ; print(platform.python_version())" 2>/dev/null || true)

if [ -z "$PYVER" ]; then
  # No python. That's a problem.
  cat <<EOF >&2
You don't seem to have Python installed! To get that sorted out,
check out https://www.python.org.
EOF
  exit 1
fi

if [ $(echo "$PYVER" | egrep -c '^2\.') -eq 0 ]; then
  # We need python 2.
  cat <<"EOF" >&2
You seem to have Python $PYVER installed. We only support Python 2,
and we need 2.7 or higher. Check out https://www.python.org to get
that sorted out.
EOF
  exit 1
fi

if ! command -v pip >/dev/null 2>&1; then
  # No pip. That's a problem.
  cat <<EOF >&2
You don't seem to have pip installed. The easiest way to fix this may
be to install and use virtualenv -- for more information, check out
https://virtualenv.pypa.io/en/stable.
EOF
  exit 1
fi

QVER=$(quark --version 2>/dev/null || true)

if [ -z "$QVER" -a -f $HOME/.quark/config.sh ]; then
  # Pull in this version of Quark and try again.
  . $HOME/.quark/config.sh

  QVER=$(quark --version 2>/dev/null || true)
fi

if [ -n "$QVER" ]; then
  if [ $(echo "$QVER" | egrep -c '^Quark 1\.0\.') -ne 1 ]; then
    # We need Quark 1.0.
    cat <<EOF >&2
You seem to have $QVER already installed. We presently need Quark 1.0.
If you remove your existing Quark and rerun this installer, we'll install
Quark 1.0 for you.
EOF
    exit 1
  fi

  # If here, we're good.
  echo "== MDK found $QVER, good"
else
  # No Quark at all. Install.
  echo "== MDK needs the Quark compiler; installing it now."

  curl -# -L https://raw.githubusercontent.com/datawire/quark/master/install.sh | bash -s -- -q v1.0.319

  . $HOME/.quark/config.sh
fi

# Compile quark packages.
echo "== Compiling the MDK"
quark install $LANGUAGE https://raw.githubusercontent.com/datawire/mdk/${BRANCH}/quark/mdk-2.0.q

# All done.
echo "== All done"
