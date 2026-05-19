# main.py 

from config import FFT_SIZE
from pipeline import run_pipeline, ESTIMATORS, velocity_to_doppler, doppler_to_velocity
from data_loader import make_sine, make_two_targets, load_scope_csv, prepare_scope_signal
from plotting import plot_raw_signal, plot_pipeline_stages, plot_estimator_comparison

MODE = 'synthetic' # 'synthetic' or 'real'
CSV_FILE = 'data/scope_1.csv' # only used when MODE = 'real'

# Which estimators to compare - comment out if dont want part of processing
ACTIVE_ESTIMATORS = [
    'zero_crossing',
    'argmax',
    'cma',
    'xca',
]

# Pipeline settings
WINDOW_TYPE = 'hamming'   # 'hamming', 'hanning', 'blackman', 'rectangular'
USE_CFAR    = True

# Synthetic signal settings (only used when MODE = 'synthetic')
SYNTHETIC_TESTS = [
    # (velocity m/s, noise amplitude, label)
    (5.0,  0.0,  'clean signal'),
    (5.0,  0.5,  'moderate noise'),
    (5.0,  1.5,  'heavy noise'),
    (15.0, 0.3,  'fast + noise'),
    (0.5,  0.1,  'very slow — hardest case'),
]

def run_synthetic():
    print(f"\n{'='*60}")
    print("SYNTHETIC MODE")
    print(f"Window: {WINDOW_TYPE}  |  CFAR: {USE_CFAR}")
    print(f"Estimators: {ACTIVE_ESTIMATORS}")
    print(f"{'='*60}")

    for velocity, noise, label in SYNTHETIC_TESTS:
        print(f"\n── {label} ({velocity} m/s, noise={noise}) ──")
        samples, true_freq = make_sine(velocity, noise_amplitude=noise)

        # Print comparison table
        print(f"{'Estimator':<16} {'Freq (Hz)':>10} {'m/s':>8} {'Error %':>9}")
        print('-' * 47)

        results = {}
        for est in ACTIVE_ESTIMATORS:
            r = run_pipeline(samples,
                             window_type=WINDOW_TYPE,
                             use_cfar=USE_CFAR,
                             estimator=est)
            error = abs(r['velocity'] - velocity) / velocity * 100
            print(f"{est:<16} {r['peak_freq']:>10.1f} "
                  f"{r['velocity']:>8.3f} {error:>9.2f}%")
            results[est] = r

        # Save comparison plot
        safe_label = label.replace(' ', '_').replace('/', '')
        plot_estimator_comparison(
            results,
            true_freq=true_freq,
            title=f"{label}  |  window={WINDOW_TYPE}  cfar={USE_CFAR}",
            filename=f'synthetic_comparison_{safe_label}.png'
        )

        # Save detailed pipeline plot for XCA (or first active estimator)
        detail_est = 'xca' if 'xca' in ACTIVE_ESTIMATORS else ACTIVE_ESTIMATORS[0]
        plot_pipeline_stages(
            results[detail_est],
            true_freq=true_freq,
            filename=f'synthetic_pipeline_{safe_label}.png'
        )

def run_real():
    print(f"\n{'='*60}")
    print(f"REAL DATA MODE — {CSV_FILE}")
    print(f"Window: {WINDOW_TYPE}  |  CFAR: {USE_CFAR}")
    print(f"Estimators: {ACTIVE_ESTIMATORS}")
    print(f"{'='*60}\n")

    times, voltages = load_scope_csv(CSV_FILE)
    frame, _ = prepare_scope_signal(times, voltages, frame_size=FFT_SIZE)

    # Plot raw signal for inspection
    plot_raw_signal(times, voltages,
                    voltages - voltages.mean(),
                    filename='raw_signal.png')

    print(f"\n{'Estimator':<16} {'Freq (Hz)':>10} {'m/s':>8} {'km/h':>8}")
    print('-' * 46)

    results = {}
    for est in ACTIVE_ESTIMATORS:
        r = run_pipeline(frame,
                         window_type=WINDOW_TYPE,
                         use_cfar=USE_CFAR,
                         estimator=est)
        print(f"{est:<16} {r['peak_freq']:>10.1f} "
              f"{r['velocity']:>8.3f} {r['velocity']*3.6:>8.1f}")
        results[est] = r

    plot_estimator_comparison(
        results,
        title=f"Real data: {CSV_FILE}  |  window={WINDOW_TYPE}  cfar={USE_CFAR}",
        filename='real_comparison.png'
    )

    detail_est = 'xca' if 'xca' in ACTIVE_ESTIMATORS else ACTIVE_ESTIMATORS[0]
    plot_pipeline_stages(results[detail_est], filename=detail_est + 'real_pipeline.png')


if __name__ == '__main__':
    if MODE == 'synthetic':
        run_synthetic()
    elif MODE == 'real':
        run_real()
    else:
        raise ValueError(f"MODE must be 'synthetic' or 'real', got '{MODE}'")
