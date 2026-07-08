"""Pin runtime dependencies for the interactive CLI."""

  Pip requirements files need # comments, not Python docstrings.

  Fastest clean path: use a venv and install the two deps directly.

  cd /path/to/lunarwing

  python3 -m venv .venv-mt-onboard
  . .venv-mt-onboard/bin/activate
  python -m pip install rich questionary

  sudo .venv-mt-onboard/bin/python -m lunarwing_mt_onboard

  If you want to keep using the requirements file, edit its first line to:

  # Pin runtime dependencies for the interactive CLI.

  Then from the repo root:

  python -m pip install -r lunarwing_mt_onboard/requirements.txt
  sudo .venv-mt-onboard/bin/python -m lunarwing_mt_onboard
