pub mod client;
pub mod server;
pub mod tor;
pub mod types;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
