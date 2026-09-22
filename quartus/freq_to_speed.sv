// freq_to_speed.sv - Doppler frequency -> speed
// v_kmh = f_Hz / (44.7 * cos(theta))
// 44.7 Hz per km/h @ 24.125 GHz head-on Doppler shift, per
// pdfs/KLC6_Filter_Design_Rationale.pdf sec 3.1 (independently re-derived
// from f_d = 2*v*cos(theta)/lambda and confirmed to match exactly).
//
// Using compile time constant:
// accounting for angle and conversion factor (not div cause expensive)
// cos() not computable realtime
//
//   - freq_scaled (from bin_to_freq) = f_Hz * 16   [FREQ_FRAC_BITS = 4]
//   - v_kmh = freq_scaled / (16 * 44.7 * cos(theta))
//   - DENOM = 16 * 44.7 * cos(40 deg) = 16 * 44.7 * 0.766044 = 547.88
//   - K_INT = round(2^K_FRAC_BITS / DENOM) = round(65536 / 547.88) = 120
//   - => speed_scaled = freq_scaled * K_INT  represents  v_kmh * 2^K_FRAC_BITS
//
// K_FRAC_BITS doubles as both the reciprocal's stored precision AND the
// output's fractional bit count - deliberate, avoids a separate shift.
// 16 bits gives ~0.3% error on the constant itself, negligible next to the
// ~0.8 km/h/bin quantization error that already dominates at this mount
// angle (see bin_to_freq.sv / project notes).
//
// 40 degrees is the currently-measured physical mount angle (previously
// this file assumed 50 degrees, which was never actually measured against
// the hardware - that inflated every speed reading by ~19%). If the
// physical mount ever changes before the PCB build, re-measure and redo
// this by hand.
//
// *** IMPORTANT: MOUNT_ANGLE_DEG below is DOCUMENTATION ONLY. Changing it
// does NOT change K_INT - they are independent parameters because K_INT
// can't be derived from MOUNT_ANGLE_DEG in synthesizable code. If the mount
// angle ever changes, K_INT must be recalculated by hand using the formula
// above and updated here manually, or the two will silently disagree. ***

module freq_to_speed #(
    parameter int MOUNT_ANGLE_DEG = 40,   // documentation only - see warning above
    parameter int K_FRAC_BITS     = 16,
    parameter int K_INT           = 120,  // = round(2^K_FRAC_BITS / (16*44.7*cos(MOUNT_ANGLE_DEG))) - recompute by hand if angle changes
    parameter int FREQ_WIDTH      = 20
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                     freq_valid,
    input  logic [FREQ_WIDTH-1:0]    freq_scaled,   // Hz * 16, from bin_to_freq

    output logic                     speed_valid,
    output logic [39:0]              speed_scaled   // km/h * 2^K_FRAC_BITS
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        speed_valid  <= 1'b0;
        speed_scaled <= '0;
    end else begin
        speed_valid <= freq_valid;
        if (freq_valid)
            speed_scaled <= freq_scaled * K_INT[15:0];
    end
end

endmodule
