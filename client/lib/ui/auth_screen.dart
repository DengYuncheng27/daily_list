import 'package:flutter/material.dart';

import '../core/app_controller.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.controller, this.onBack});
  final AppController controller;
  final VoidCallback? onBack;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  late final TextEditingController server;
  bool register = false;
  bool busy = false;
  bool visible = false;
  String? error;
  @override
  void initState() {
    super.initState();
    server = TextEditingController(text: widget.controller.serverUrl);
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    name.dispose();
    server.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (register) {
        await widget.controller.register(
          email: email.text.trim(),
          password: password.text,
          name: name.text.trim(),
          serverUrl: server.text.trim(),
        );
      } else {
        await widget.controller.signIn(
          email: email.text.trim(),
          password: password.text,
          serverUrl: server.text.trim(),
        );
      }
      if (mounted) widget.onBack?.call();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF7F8FC),
    body: LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          if (constraints.maxWidth > 1100)
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(55),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF0FB),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.view_day_rounded,
                          color: Color(0xFF5C6FE8),
                          size: 32,
                        ),
                        SizedBox(width: 12),
                        Text(
                          '日序',
                          style: TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 3,
                          ),
                        ),
                        SizedBox(width: 12),
                        Text(
                          'DAYFLOW',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 2.4,
                            color: Color(0xFF8B92B0),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    const Text(
                      '让每件事，\n都有自己的时间。',
                      style: TextStyle(
                        fontSize: 40,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -1.2,
                        color: Color(0xFF303956),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '清单与月历，让每天更有条理。\n从桌面到口袋，接着上次的进度。',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.9,
                        color: Color(0xFF8A91A9),
                      ),
                    ),
                    const SizedBox(height: 48),
                    _illustration(),
                    const Spacer(),
                    const Text(
                      'WINDOWS  /  WEB  /  ANDROID  /  iOS',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.4,
                        color: Color(0xFF9DA4BC),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Form(
                    key: form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.onBack != null)
                          TextButton.icon(
                            onPressed: widget.onBack,
                            icon: const Icon(Icons.arrow_back_rounded),
                            label: const Text('返回'),
                          ),
                        if (constraints.maxWidth <= 1100) ...[
                          const Icon(
                            Icons.view_day_rounded,
                            color: Color(0xFF5C6FE8),
                            size: 38,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            '日序 Dayflow',
                            style: TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 32),
                        ],
                        Text(
                          register ? '开启你的日序' : '欢迎回来',
                          style: const TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -.7,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          register ? '创建账号，在你的设备间同步任务。' : '登录账号，继续安排接下来的日子。',
                          style: const TextStyle(
                            color: Color(0xFF979DAE),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 32),
                        if (register) ...[
                          TextFormField(
                            controller: name,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: '你的名字',
                              prefixIcon: Icon(Icons.person_outline_rounded),
                            ),
                            validator: (v) =>
                                v == null || v.trim().isEmpty ? '请填写名字' : null,
                          ),
                          const SizedBox(height: 16),
                        ],
                        TextFormField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: '邮箱',
                            prefixIcon: Icon(Icons.alternate_email_rounded),
                          ),
                          validator: (v) =>
                              v == null ||
                                  !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                      .hasMatch(v.trim())
                              ? '请输入有效邮箱'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: password,
                          obscureText: !visible,
                          onFieldSubmitted: (_) => submit(),
                          autofillHints: register
                              ? const [AutofillHints.newPassword]
                              : const [AutofillHints.password],
                          decoration: InputDecoration(
                            labelText: register ? '密码（至少 10 位）' : '密码',
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              tooltip: visible ? '隐藏密码' : '显示密码',
                              onPressed: () =>
                                  setState(() => visible = !visible),
                              icon: Icon(
                                visible
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 20,
                              ),
                            ),
                          ),
                          validator: (v) =>
                              v == null || v.length < (register ? 10 : 1)
                              ? '请填写${register ? '至少 10 位的' : ''}密码'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 14),
                          title: const Text(
                            '服务器地址',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8C93A4),
                            ),
                          ),
                          subtitle: Text(
                            server.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          children: [
                            TextFormField(
                              controller: server,
                              keyboardType: TextInputType.url,
                              decoration: const InputDecoration(
                                hintText: 'https://tasks.example.com',
                                helperText: '填写你部署的日序服务器地址',
                              ),
                              validator: (v) {
                                final uri = Uri.tryParse(v?.trim() ?? '');
                                return uri == null ||
                                        ![
                                          'http',
                                          'https',
                                        ].contains(uri.scheme) ||
                                        uri.host.isEmpty
                                    ? '请输入完整的服务器地址'
                                    : null;
                              },
                            ),
                          ],
                        ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                                height: 1.6,
                              ),
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: busy ? null : submit,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 48),
                            ),
                            child: busy
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(register ? '创建账号' : '登录'),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              register ? '已经有账号？' : '第一次使用？',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF9298A9),
                              ),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => setState(() {
                                      register = !register;
                                      error = null;
                                    }),
                              child: Text(register ? '去登录' : '创建账号'),
                            ),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Divider(),
                        ),
                        Center(
                          child: TextButton.icon(
                            onPressed: busy
                                ? null
                                : () async {
                                    await widget.controller.enterDemo();
                                    if (mounted) widget.onBack?.call();
                                  },
                            icon: const Icon(Icons.explore_outlined, size: 17),
                            label: const Text(
                              '先体验一下',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const Center(
                          child: Text(
                            '独立示例空间 · 无需账号 · 不会上传',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFFAAB0BD),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _illustration() => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        const Row(
          children: [
            Text(
              '每一天，向前一点',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF7F87A6),
              ),
            ),
            Spacer(),
            Icon(Icons.more_horiz_rounded, color: Color(0xFFA2AAC3)),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: List.generate(
            7,
            (i) => Expanded(
              child: Column(
                children: [
                  Text(
                    ['M', 'T', 'W', 'T', 'F', 'S', 'S'][i],
                    style: const TextStyle(
                      color: Color(0xFFA2AAC3),
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: 29,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == 2
                          ? const Color(0xFF5C6FE8)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      '${12 + i}',
                      style: TextStyle(
                        color: i == 2 ? Colors.white : const Color(0xFF8590AD),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        ...['整理今天的想法', '把计划写进日历'].asMap().entries.map(
          (e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  e.key == 0
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 17,
                  color: const Color(0xFFA4AFDC),
                ),
                const SizedBox(width: 10),
                Text(
                  e.value,
                  style: TextStyle(
                    fontSize: 12,
                    color: const Color(0xFF8690AE),
                    decoration: e.key == 0 ? TextDecoration.lineThrough : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
