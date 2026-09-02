// ============================================================
// ADMIN LOGIN SCREEN
// Accessed via long-pressing the logo on the Login Screen
// ============================================================
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'admin_panel_screen.dart';

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});
  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey            = GlobalKey<FormState>();
  bool   _loading           = false;
  bool   _obscure           = true;
  bool   _showForgot        = false;
  String? _error;

  // Forgot password fields
  final _forgotUsernameController = TextEditingController();
  final _otpController            = TextEditingController();
  final _newPasswordController    = TextEditingController();
  String? _otpFromServer;
  bool    _otpSent   = false;
  bool    _fpLoading = false;
  String? _fpMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _forgotUsernameController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await ApiService.adminLogin(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      if (result['success'] == true && mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => AdminPanelScreen(
            username:  result['username'],
            role:      result['role'],
            fullName:  result['full_name'] ?? '',
            district:  result['district'],
            crop:      result['crop'],
          )));
      } else {
        setState(() => _error = result['message'] ?? 'Invalid credentials');
      }
    } catch (e) {
      setState(() => _error = 'Could not connect to server. Is Flask running?');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestOtp() async {
    final username = _forgotUsernameController.text.trim();
    if (username.isEmpty) {
      setState(() => _fpMessage = 'Enter your username first');
      return;
    }
    setState(() { _fpLoading = true; _fpMessage = null; });
    try {
      final result = await ApiService.forgotPasswordRequest(username: username);
      if (result['success'] == true) {
        setState(() {
          _otpFromServer = result['otp'];
          _otpSent       = true;
          _fpMessage     = 'OTP generated. Use the code below to reset your password.';
        });
      } else {
        setState(() => _fpMessage = result['error'] ?? 'Username not found');
      }
    } catch (e) {
      setState(() => _fpMessage = 'Server error: $e');
    } finally {
      if (mounted) setState(() => _fpLoading = false);
    }
  }

  Future<void> _resetPassword() async {
    if (_otpController.text.trim() != _otpFromServer) {
      setState(() => _fpMessage = 'Incorrect OTP. Please check and try again.');
      return;
    }
    if (_newPasswordController.text.length < 6) {
      setState(() => _fpMessage = 'Password must be at least 6 characters.');
      return;
    }
    setState(() { _fpLoading = true; _fpMessage = null; });
    try {
      final result = await ApiService.forgotPasswordReset(
        username:    _forgotUsernameController.text.trim(),
        otp:         _otpController.text.trim(),
        newPassword: _newPasswordController.text,
      );
      if (result['success'] == true) {
        setState(() {
          _showForgot = false;
          _otpSent    = false;
          _fpMessage  = null;
          _fpLoading  = false;
          _error      = null;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Password reset successfully. Please log in.'),
            backgroundColor: Colors.green,
          ));
        }
      } else {
        setState(() => _fpMessage = result['error'] ?? 'Reset failed');
      }
    } catch (e) {
      setState(() => _fpMessage = 'Server error: $e');
    } finally {
      if (mounted) setState(() => _fpLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Login')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _showForgot ? _buildForgotPassword() : _buildLoginForm(),
        ),
      ),
    );
  }

  Widget _buildLoginForm() {
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.admin_panel_settings, size: 48, color: Colors.grey),
        const SizedBox(height: 16),
        Text('DEA Staff / Admin Login',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Authorised users only.',
            style: TextStyle(color: Colors.grey[600], fontSize: 13)),
        const SizedBox(height: 32),

        TextFormField(
          controller: _usernameController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Username',
            prefixIcon: Icon(Icons.person_outline),
          ),
          validator: (v) => v == null || v.isEmpty ? 'Enter username' : null,
        ),
        const SizedBox(height: 16),

        TextFormField(
          controller: _passwordController,
          obscureText: _obscure,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _login(),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(_obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              tooltip: _obscure ? 'Show password' : 'Hide password',
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          validator: (v) => v == null || v.isEmpty ? 'Enter password' : null,
        ),

        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() => _showForgot = true),
            child: const Text('Forgot password?'),
          ),
        ),

        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red[50],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
          ),
          const SizedBox(height: 12),
        ],

        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _loading ? null : _login,
            child: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Text('Login'),
          ),
        ),
      ]),
    );
  }

  Widget _buildForgotPassword() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to login',
          onPressed: () => setState(() {
            _showForgot = false; _otpSent = false;
            _fpMessage  = null; _otpFromServer = null;
          }),
          padding: EdgeInsets.zero,
        ),
        const SizedBox(width: 8),
        Text('Reset Password',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 24),

      TextFormField(
        controller: _forgotUsernameController,
        decoration: const InputDecoration(
          labelText: 'Your username',
          prefixIcon: Icon(Icons.person_outline),
        ),
      ),
      const SizedBox(height: 16),

      SizedBox(
        width: double.infinity,
        height: 44,
        child: ElevatedButton(
          onPressed: (_fpLoading || _otpSent) ? null : _requestOtp,
          child: _fpLoading
              ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Text('Generate OTP'),
        ),
      ),

      if (_otpFromServer != null) ...[
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.amber[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.amber[300]!),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Your OTP code:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(_otpFromServer!,
                style: const TextStyle(fontSize: 32,
                    fontWeight: FontWeight.bold, letterSpacing: 8)),
            const SizedBox(height: 4),
            const Text('Valid for 15 minutes.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
        const SizedBox(height: 16),

        TextFormField(
          controller: _otpController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Enter OTP',
            prefixIcon: Icon(Icons.security),
          ),
        ),
        const SizedBox(height: 12),

        TextFormField(
          controller: _newPasswordController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'New password',
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 16),

        SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton(
            onPressed: _fpLoading ? null : _resetPassword,
            child: _fpLoading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Text('Reset Password'),
          ),
        ),
      ],

      if (_fpMessage != null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _fpMessage!.contains('generated') || _fpMessage!.contains('OTP')
                ? Colors.green[50]
                : Colors.red[50],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(_fpMessage!,
              style: TextStyle(
                  color: _fpMessage!.contains('generated') || _fpMessage!.contains('OTP')
                      ? Colors.green[800]
                      : Colors.red,
                  fontSize: 13)),
        ),
      ],
    ]);
  }
}