<?php
/**
 * Plugin Name: Certify Exam Bridge
 * Description: Tutor LMS ↔ Certify Studio. Adds the [certify_exam_apply] shortcode. After checking enrollment it asks a Supabase Edge Function (Resend email) to send the one-time exam link. Certificates are emailed by Supabase after the student passes.
 * Version:     2.0.0
 * Requires PHP: 7.4
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

const CEB_OPTION = 'ceb_settings';

/* ------------------------------------------------------------------ */
/* Settings                                                            */
/* ------------------------------------------------------------------ */

function ceb_opts() {
	return wp_parse_args(
		get_option( CEB_OPTION, array() ),
		array(
			'supabase_url'       => '',
			'secret'             => '',
			'require_completion' => 'no',
		)
	);
}

function ceb_is_configured() {
	$o = ceb_opts();
	return $o['supabase_url'] && $o['secret'];
}

add_action( 'admin_menu', function () {
	add_options_page( 'Certify Exam Bridge', 'Certify Exam Bridge', 'manage_options', 'certify-exam-bridge', 'ceb_settings_page' );
} );

add_action( 'admin_init', function () {
	register_setting(
		'ceb_group',
		CEB_OPTION,
		array(
			'sanitize_callback' => function ( $in ) {
				return array(
					'supabase_url'       => esc_url_raw( untrailingslashit( trim( $in['supabase_url'] ?? '' ) ) ),
					'secret'             => sanitize_text_field( $in['secret'] ?? '' ),
					'require_completion' => ( ( $in['require_completion'] ?? 'no' ) === 'yes' ) ? 'yes' : 'no',
				);
			},
		)
	);
} );

function ceb_settings_page() {
	$o = ceb_opts();
	?>
	<div class="wrap">
		<h1>Certify Exam Bridge</h1>
		<form method="post" action="options.php">
			<?php settings_fields( 'ceb_group' ); ?>
			<table class="form-table" role="presentation">
				<tr><th>Supabase project URL</th><td><input class="regular-text" type="url" name="<?php echo CEB_OPTION; ?>[supabase_url]" value="<?php echo esc_attr( $o['supabase_url'] ); ?>" placeholder="https://xxxx.supabase.co"></td></tr>
				<tr><th>Bridge secret</th><td><input class="regular-text" type="text" name="<?php echo CEB_OPTION; ?>[secret]" value="<?php echo esc_attr( $o['secret'] ); ?>"><p class="description">Copy it from Certify Studio → Settings → WordPress automation.</p></td></tr>
				<tr><th>Require course completion</th><td><label><input type="checkbox" name="<?php echo CEB_OPTION; ?>[require_completion]" value="yes" <?php checked( $o['require_completion'], 'yes' ); ?>> Only students who completed the course can apply (default for every shortcode)</label></td></tr>
			</table>
			<?php submit_button(); ?>
		</form>
		<h2>Shortcode</h2>
		<p><code>[certify_exam_apply]</code> — place it inside a Tutor course (description, lesson or course page).<br>
		Specific exam: <code>[certify_exam_apply exam_id="EXAM_ID"]</code> (copy it from the exam page in Certify Studio).<br>
		Optional: <code>course_id="123"</code> <code>label="Apply for Exam"</code> <code>require_completion="yes|no"</code></p>
	</div>
	<?php
}

/* ------------------------------------------------------------------ */
/* Shortcode                                                           */
/* ------------------------------------------------------------------ */

function ceb_resolve_course_id( $atts ) {
	if ( ! empty( $atts['course_id'] ) ) {
		return (int) $atts['course_id'];
	}
	$id = get_the_ID();
	if ( ! $id ) {
		return 0;
	}
	if ( 'courses' === get_post_type( $id ) ) {
		return (int) $id;
	}
	if ( function_exists( 'tutor_utils' ) ) {
		$u = tutor_utils();
		if ( method_exists( $u, 'get_course_id_by_subcontent' ) ) {
			$cid = $u->get_course_id_by_subcontent( $id );
			if ( $cid ) {
				return (int) $cid;
			}
		}
		if ( method_exists( $u, 'get_course_id_by' ) ) {
			foreach ( array( 'lesson', 'quiz', 'assignment' ) as $type ) {
				$cid = $u->get_course_id_by( $type, $id );
				if ( $cid ) {
					return (int) $cid;
				}
			}
		}
	}
	return (int) $id;
}

function ceb_user_enrolled( $course_id, $user_id ) {
	return function_exists( 'tutor_utils' ) && (bool) tutor_utils()->is_enrolled( $course_id, $user_id );
}

function ceb_user_completed( $course_id, $user_id ) {
	return function_exists( 'tutor_utils' ) && (bool) tutor_utils()->is_completed_course( $course_id, $user_id );
}

add_shortcode( 'certify_exam_apply', function ( $atts ) {
	$atts = shortcode_atts(
		array(
			'course_id'          => '',
			'exam_id'            => '',
			'label'              => 'Apply for Exam',
			'require_completion' => '',
		),
		$atts,
		'certify_exam_apply'
	);

	if ( ! is_user_logged_in() ) {
		return '<div class="ceb-apply"><p>Please <a href="' . esc_url( wp_login_url( get_permalink() ) ) . '">log in</a> to apply for the exam.</p></div>';
	}

	$course_id = ceb_resolve_course_id( $atts );
	if ( ! $course_id ) {
		return '';
	}
	if ( ! ceb_user_enrolled( $course_id, get_current_user_id() ) ) {
		return '<div class="ceb-apply"><p>You need to be enrolled in this course to apply for the exam.</p></div>';
	}

	$exam_id = sanitize_text_field( $atts['exam_id'] );
	$require = $atts['require_completion'] ? $atts['require_completion'] : ceb_opts()['require_completion'];

	static $assets = false;
	if ( ! $assets ) {
		$assets = true;
		add_action( 'wp_footer', 'ceb_print_assets' );
	}

	ob_start();
	?>
	<div class="ceb-apply" data-course="<?php echo esc_attr( $course_id ); ?>" data-require="<?php echo esc_attr( $require ); ?>" data-exam="<?php echo esc_attr( $exam_id ); ?>" data-sig="<?php echo esc_attr( wp_hash( $course_id . '|' . $require . '|' . $exam_id ) ); ?>" data-nonce="<?php echo esc_attr( wp_create_nonce( 'ceb_apply' ) ); ?>">
		<button type="button" class="ceb-btn"><?php echo esc_html( $atts['label'] ); ?></button>
		<p class="ceb-msg" role="status" aria-live="polite"></p>
	</div>
	<?php
	return ob_get_clean();
} );

function ceb_print_assets() {
	$ajax = esc_url( admin_url( 'admin-ajax.php' ) );
	?>
	<style>
		.ceb-apply{margin:16px 0}
		.ceb-btn{background:#2563eb;color:#fff;border:0;border-radius:8px;padding:12px 22px;font-size:16px;font-weight:600;cursor:pointer}
		.ceb-btn[disabled]{opacity:.6;cursor:wait}
		.ceb-msg{margin:10px 0 0;font-size:15px}
		.ceb-msg.ok{color:#15803d}.ceb-msg.err{color:#b91c1c}
	</style>
	<script>
	document.querySelectorAll('.ceb-apply[data-course]').forEach(function (box) {
		var btn = box.querySelector('.ceb-btn'), msg = box.querySelector('.ceb-msg');
		btn.addEventListener('click', function () {
			btn.disabled = true; msg.className = 'ceb-msg'; msg.textContent = 'Sending your exam link…';
			var body = new URLSearchParams({
				action: 'ceb_apply', nonce: box.dataset.nonce,
				course_id: box.dataset.course, require: box.dataset.require, exam_id: box.dataset.exam, sig: box.dataset.sig
			});
			fetch('<?php echo $ajax; ?>', { method: 'POST', body: body, credentials: 'same-origin' })
				.then(function (r) { return r.json(); })
				.then(function (j) {
					var ok = j && j.success;
					msg.className = 'ceb-msg ' + (ok ? 'ok' : 'err');
					msg.textContent = (j && j.data && j.data.message) || (ok ? 'Done.' : 'Something went wrong.');
					if (!ok) btn.disabled = false;
				})
				.catch(function () { msg.className = 'ceb-msg err'; msg.textContent = 'Network error. Please try again.'; btn.disabled = false; });
		});
	});
	</script>
	<?php
}

/* ------------------------------------------------------------------ */
/* Apply → Supabase Edge Function creates the link and emails it       */
/* ------------------------------------------------------------------ */

add_action( 'wp_ajax_ceb_apply', function () {
	check_ajax_referer( 'ceb_apply', 'nonce' );

	$user_id   = get_current_user_id();
	$course_id = (int) ( $_POST['course_id'] ?? 0 );
	if ( ! $user_id || ! $course_id ) {
		wp_send_json_error( array( 'message' => 'Invalid request.' ) );
	}
	if ( ! ceb_is_configured() ) {
		wp_send_json_error( array( 'message' => 'The exam service is not configured yet.' ) );
	}
	if ( get_transient( 'ceb_rl_' . $user_id . '_' . $course_id ) ) {
		wp_send_json_error( array( 'message' => 'Please wait a minute before requesting another link.' ) );
	}
	if ( ! ceb_user_enrolled( $course_id, $user_id ) ) {
		wp_send_json_error( array( 'message' => 'You are not enrolled in this course.' ) );
	}
	// The shortcode's completion rule is signed, so a student cannot weaken it from the browser.
	$req_raw = sanitize_text_field( $_POST['require'] ?? 'no' );
	$sig     = sanitize_text_field( $_POST['sig'] ?? '' );
	$exam_id = sanitize_text_field( $_POST['exam_id'] ?? '' );
	if ( ! hash_equals( wp_hash( $course_id . '|' . $req_raw . '|' . $exam_id ), $sig ) ) {
		wp_send_json_error( array( 'message' => 'Invalid request. Please reload the page.' ) );
	}
	$require = ( 'yes' === $req_raw ) || ( 'yes' === ceb_opts()['require_completion'] );
	if ( $require && ! ceb_user_completed( $course_id, $user_id ) ) {
		wp_send_json_error( array( 'message' => 'Complete the course first, then apply for the exam.' ) );
	}

	$user = wp_get_current_user();
	$name = trim( $user->first_name . ' ' . $user->last_name );
	$name = $name ? $name : $user->display_name;
	$o    = ceb_opts();

	$res = wp_remote_post(
		$o['supabase_url'] . '/functions/v1/request-exam',
		array(
			'timeout' => 30,
			'headers' => array(
				'Content-Type'     => 'application/json',
				'X-Certify-Secret' => $o['secret'],
			),
			'body'    => wp_json_encode(
				array(
					'course_id' => (string) $course_id,
					'exam_id'   => $exam_id,
					'user_id'   => (string) $user_id,
					'name'      => $name,
					'email'     => $user->user_email,
				)
			),
		)
	);

	if ( is_wp_error( $res ) ) {
		error_log( 'Certify Exam Bridge: ' . $res->get_error_message() );
		wp_send_json_error( array( 'message' => 'The exam service is unavailable. Please try again later.' ) );
	}
	$data = json_decode( wp_remote_retrieve_body( $res ), true );
	if ( empty( $data['ok'] ) ) {
		wp_send_json_error( array( 'message' => $data['message'] ?? 'Could not create your exam link.' ) );
	}

	set_transient( 'ceb_rl_' . $user_id . '_' . $course_id, 1, MINUTE_IN_SECONDS );
	wp_send_json_success( array( 'message' => $data['message'] ) );
} );

/* Clean up the cron job used by version 1 of this plugin. */
add_action( 'init', function () {
	wp_clear_scheduled_hook( 'ceb_cron_deliver' );
} );
