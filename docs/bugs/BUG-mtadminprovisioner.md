- lunarwing_mt_onboard/provisioner.py:60 now lets
    run_command() take an explicit phase_name;
    lunarwing_mt_onboard/upgrade.py:221 passes
    preflight and upgrade, while keeping tenant argv
    unchanged for the scripts.
