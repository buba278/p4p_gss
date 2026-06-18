# main.py 

from config import FFT_SIZE
from pipeline import run_pipeline, ESTIMATORS, velocity_to_doppler, doppler_to_velocity
from data_loader import make_sine, load_scope_csv, prepare_scope_signal
from plotting import plot_raw_signal, plot_estimator_comparison

MODE = 'synthetic' # 'synthetic' or 'real'
CSV_FILE = 'data/scope_1.csv' 

ACTIVE_ESTIMATORS = [
    'zero_crossing',
    'argmax',
    'cma',
    'xca',
]

WINDOW_TYPE = 'hamming'   
USE_CFAR    = True

# Synthetic signal settings — now supports simple parameter mixing!
SYNTHETIC_TESTS = [
    # (velocity m/s, noise configuration, label)
    (5.0,  0.0,  'clean signal'),
    (5.0,  0.5,  'moderate white noise'),
    
    # Test 1: High background white noise combined with engine rattle
    (15.0, {'white': 0.8, 'vibration': 0.25}, 'high speed + heavy engine vibe'),
    
    # Test 2: Electronics Flicker noise (creates a massive amplitude wall near 0 Hz)
    (8.0,  {'flicker': 0.7}, 'heavy electrical flicker noise'),
    
    # Test 3: Hitting a puddle on a realistic rough track surface
    (5.0,  {'white': 0.2, 'dropout': True, 'beam_spread': 0.04}, 'wet track dropout + beam spread'),
    
    # Test 4: The nightmare scenario (Ultra slow speed + combined structural noises)
    (0.5,  {'white': 0.2, 'flicker': 0.3, 'vibration': 0.1}, 'slow + absolute worst case combo'),
]

def run_synthetic():
    print(f"\n{'='*60}")
    print("SYNTHETIC MODE")
    print(f"Window: {WINDOW_TYPE}  |  CFAR: {USE_CFAR}")
    print(f"Estimators: {ACTIVE_ESTIMATORS}")
    print(f"{'='*60}")

    for velocity, noise, label in SYNTHETIC_TESTS:
        print(f"\n── {label} ({velocity} m/s) ──")
        # Call updated function mapping noise directly
        samples, true_freq = make_sine(velocity, noise_config=noise)

        print(f"{'Estimator':<16} {'Freq (Hz)':>10} {'m/s':>8} {'Error %':>9}")
        print('-' * 47)

        results = {}
        for est in ACTIVE_ESTIMATORS:
            r = run_pipeline(samples,
                             window_type=WINDOW_TYPE,
                             use_cfar=USE_CFAR,
                             estimator=est)
            
            # Avoid division by zero if testing true 0 m/s
            denom = velocity if velocity != 0 else 0.001
            error = abs(r['velocity'] - velocity) / denom * 100
            
            print(f"{est:<16} {r['peak_freq']:>10.1f} "
                  f"{r['velocity']:>8.3f} {error:>9.2f}%")
            results[est] = r

        safe_label = label.replace(' ', '_').replace('/', '').replace('+', 'and')
        plot_estimator_comparison(
            results,
            true_freq=true_freq,
            title=f"{label}  |  window={WINDOW_TYPE}  cfar={USE_CFAR}",
            filename=f'synthetic_comparison_{safe_label}.png'
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

if __name__ == '__main__':
    if MODE == 'synthetic':
        run_synthetic()
    elif MODE == 'real':
        run_real()
    else:
        raise ValueError(f"MODE must be 'synthetic' or 'real', got '{MODE}'")
