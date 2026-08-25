#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
jar_path=${1:-${TLA2TOOLS_JAR:-}}
java_bin=${JAVA_BIN:-java}
trace_count=${HYBRID_TRACE_COUNT:-10000}
trace_depth=${HYBRID_TRACE_DEPTH:-100}
simulation_workers=${HYBRID_SIMULATION_WORKERS:-8}
seed_list=${HYBRID_SEEDS:-"2026082401 2026082402 2026082403 2026082404"}
run_stamp=$(date +%Y%m%d-%H%M%S)
output_root=${HYBRID_OUTPUT_ROOT:-/tmp/notation-tlc-hybrid-${run_stamp}}

if [[ -z ${jar_path} || ! -f ${jar_path} ]]; then
    print -u2 "usage: $0 /path/to/tla2tools.jar"
    exit 2
fi
if [[ ${trace_count} != <-> || ${trace_count} -lt 1 ]]; then
    print -u2 "HYBRID_TRACE_COUNT must be a positive integer"
    exit 2
fi
if [[ ${trace_depth} != <-> || ${trace_depth} -lt 1 ]]; then
    print -u2 "HYBRID_TRACE_DEPTH must be a positive integer"
    exit 2
fi
if [[ ${simulation_workers} != <-> || ${simulation_workers} -lt 1 ]]; then
    print -u2 "HYBRID_SIMULATION_WORKERS must be a positive integer"
    exit 2
fi
if (( trace_count % simulation_workers != 0 )); then
    print -u2 "HYBRID_TRACE_COUNT must be divisible by HYBRID_SIMULATION_WORKERS"
    exit 2
fi
traces_per_worker=$((trace_count / simulation_workers))

typeset -a seeds scenarios exact_models
seeds=(${=seed_list})
if (( ${#seeds} == 0 )); then
    print -u2 "HYBRID_SEEDS must contain at least one integer"
    exit 2
fi
for seed in ${seeds}; do
    if [[ ${seed} != -<-> && ${seed} != <-> ]]; then
        print -u2 "every HYBRID_SEEDS entry must be an integer"
        exit 2
    fi
done

scenarios=(
    fastForward twoEditsMerge missingBase unsafeMerge
    deleteEdit localDeleteRemoteEdit renameRace renameOnlyRace
    renameRemoteEdit unmatchedIdentity ambiguousIdentity
    pathTimestampIdentity filenameContentIdentity multiVersion
    localEditRemoteUnchanged remoteRenameLocalEdit
    remoteRenameOnly localRenameRemoteUnchanged
    localRenameRemoteDelete localDeleteRemoteRename
    localRenameTwoEditsMerge remoteRenameTwoEditsMerge
)
exact_models=(ReconciliationDecisionSafety ReconciliationFencingSafety)

cd ${script_dir}
mkdir -p ${output_root}/{configs,logs,states,traces}
print -r -- "started=${run_stamp}" > ${output_root}/manifest.txt
print -r -- "trace_count=${trace_count}" >> ${output_root}/manifest.txt
print -r -- "trace_depth=${trace_depth}" >> ${output_root}/manifest.txt
print -r -- "simulation_workers=${simulation_workers}" >> ${output_root}/manifest.txt
print -r -- "traces_per_worker=${traces_per_worker}" >> ${output_root}/manifest.txt
print -r -- "seeds=${seed_list}" >> ${output_root}/manifest.txt
shasum -a 256 \
    ${script_dir}/ReconciliationInterface.tla \
    ${script_dir}/ReconciliationDecisionSafety.tla \
    ${script_dir}/ReconciliationDecisionSafety.cfg \
    ${script_dir}/ReconciliationFencingSafety.tla \
    ${script_dir}/ReconciliationFencingSafety.cfg \
    ${script_dir}/ReconciliationSafety.tla \
    ${script_dir}/ReconciliationSimulation.cfg.in \
    ${script_dir}/run-hybrid-reconciliation.zsh \
    ${jar_path} \
    >> ${output_root}/manifest.txt

for model in ${exact_models}; do
    print -r -- "SANY ${model}"
    ${java_bin} -cp ${jar_path} tla2sany.SANY \
        ${script_dir}/${model}.tla \
        2>&1 | tee ${output_root}/logs/${model}-sany.log

    print -r -- "TLC exhaustive ${model}"
    ${java_bin} -XX:+UseParallelGC -jar ${jar_path} \
        -workers auto \
        -lncheck final \
        -coverage 1 \
        -checkpoint 5 \
        -teSpecOutDir ${output_root}/traces \
        -metadir ${output_root}/states/${model} \
        -config ${script_dir}/${model}.cfg \
        ${script_dir}/${model}.tla \
        2>&1 | tee ${output_root}/logs/${model}-tlc.log
    if ! grep -q "Model checking completed. No error has been found." \
            ${output_root}/logs/${model}-tlc.log; then
        print -u2 "exhaustive check did not report clean completion: ${model}"
        exit 1
    fi
done

for scenario in ${scenarios}; do
    scenario_cfg=${output_root}/configs/ReconciliationSafety-${scenario}.cfg
    sed "s/@SCENARIO@/${scenario}/g" \
        ${script_dir}/ReconciliationSimulation.cfg.in > ${scenario_cfg}
    if grep -q '@SCENARIO@' ${scenario_cfg}; then
        print -u2 "scenario template substitution failed: ${scenario}"
        exit 1
    fi

    for seed in ${seeds}; do
        run_name=${scenario}-seed-${seed}
        print -r -- "TLC simulation ${run_name}"
        ${java_bin} -XX:+UseParallelGC -jar ${jar_path} \
            -workers ${simulation_workers} \
            -simulate num=${traces_per_worker} \
            -depth ${trace_depth} \
            -seed ${seed} \
            -coverage 1 \
            -teSpecOutDir ${output_root}/traces \
            -metadir ${output_root}/states/${run_name} \
            -config ${scenario_cfg} \
            ${script_dir}/ReconciliationSafety.tla \
            2>&1 | tee ${output_root}/logs/${run_name}.log
        if grep -q '^Error:' ${output_root}/logs/${run_name}.log; then
            print -u2 "simulation reported an error: ${run_name}"
            exit 1
        fi
    done
done

print -r -- "completed=$(date +%Y%m%d-%H%M%S)" \
    >> ${output_root}/manifest.txt
print -r -- "Hybrid reconciliation checks completed: ${output_root}"
