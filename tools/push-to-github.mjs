#!/usr/bin/env node
/**
 * push-to-github.mjs
 *
 * 把工程推到 GitHub，触发云端 macOS 编译。
 * 在 Windows 上跑，不需要 Mac。
 *
 * 前置：
 *   1. 装 Git：https://git-scm.com/download/win
 *   2. 装 GitHub CLI（可选但推荐）：https://cli.github.com/
 *      装完执行 `gh auth login` 登录一次
 *
 * 用法：
 *   node tools/push-to-github.mjs                     # 交互式
 *   node tools/push-to-github.mjs --repo my-reader    # 指定仓库名
 *
 * 运行： node tools/push-to-github.mjs
 */

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');

const c = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
};

function run(cmd, args, opts = {}) {
  return spawnSync(cmd, args, {
    cwd: ROOT,
    encoding: 'utf8',
    shell: process.platform === 'win32',
    ...opts,
  });
}

function has(cmd) {
  const r = run(cmd, ['--version']);
  return r.status === 0;
}

function step(n, text) {
  console.log(`\n${c.bold(`[${n}]`)} ${text}`);
}

async function main() {
  console.log(c.bold('\n把工程推到 GitHub，让云端 macOS 帮你编译 ipa\n'));

  // ── 1. 检查环境 ──
  step(1, '检查环境');
  if (!has('git')) {
    console.log(c.red('  未找到 git。'));
    console.log('  去 https://git-scm.com/download/win 下载安装，装完重开终端再跑一次。');
    process.exit(1);
  }
  const gitVersion = run('git', ['--version']).stdout.trim();
  console.log(c.green(`  ✓ ${gitVersion}`));

  const hasGh = has('gh');
  console.log(hasGh
    ? c.green('  ✓ 找到 GitHub CLI')
    : c.yellow('  ! 没装 GitHub CLI，会用普通 git 推送（需要你手动建仓库）'));

  // ── 2. 收集信息 ──
  const rl = createInterface({ input: stdin, output: stdout });

  let repoName = 'novel-reader';
  const args = process.argv.slice(2);
  const repoIdx = args.indexOf('--repo');
  if (repoIdx >= 0 && args[repoIdx + 1]) {
    repoName = args[repoIdx + 1];
  } else {
    const ans = await rl.question(`  仓库名（默认 ${repoName}）：`);
    if (ans.trim()) repoName = ans.trim();
  }

  let githubUser = '';
  if (hasGh) {
    const r = run('gh', ['api', 'user', '--jq', '.login']);
    if (r.status === 0) {
      githubUser = r.stdout.trim();
      console.log(c.green(`  已登录 GitHub：${githubUser}`));
    }
  }
  if (!githubUser) {
    githubUser = (await rl.question('  你的 GitHub 用户名：')).trim();
    if (!githubUser) {
      console.log(c.red('  必须提供用户名。'));
      process.exit(1);
    }
  }

  // ── 3. 初始化 git ──
  step(2, '初始化 Git 仓库');
  if (!existsSync(resolve(ROOT, '.git'))) {
    run('git', ['init']);
    console.log(c.green('  ✓ git init'));
  } else {
    console.log(c.dim('  已有 .git，跳过'));
  }

  // 写 .gitignore（只忽略真正该忽略的）
  const gitignorePath = resolve(ROOT, '.gitignore');
  const gitignore = [
    '# macOS',
    '.DS_Store',
    '',
    '# Xcode',
    'build/',
    'DerivedData/',
    '*.xcuserstate',
    'xcuserdata/',
    '*.xcarchive',
    '',
    '# 工具产物',
    'tools/.e2e-sandbox/',
    '',
    '# 别把签名文件传上去',
    '*.p12',
    '*.mobileprovision',
    'ExportOptions.plist',
  ].join('\n');
  if (!existsSync(gitignorePath)) {
    writeFileSync(gitignorePath, gitignore, 'utf8');
    console.log(c.green('  ✓ 写入 .gitignore'));
  }

  run('git', ['add', '-A']);
  const status = run('git', ['status', '--porcelain']);
  if (status.stdout.trim()) {
    run('git', ['-c', 'user.name=NovelReader', '-c', 'user.email=noreply@example.com',
                'commit', '-m', 'feat: iOS 小说阅读器（本地 + NAS + 在线书源）']);
    console.log(c.green('  ✓ 提交代码'));
  } else {
    console.log(c.dim('  没有新改动'));
  }
  run('git', ['branch', '-M', 'main']);

  // ── 4. 创建远程仓库 ──
  step(3, '创建 GitHub 仓库并推送');

  let pushed = false;

  if (hasGh) {
    // 用 gh 一键创建 + 推送
    const check = run('gh', ['repo', 'view', `${githubUser}/${repoName}`]);
    if (check.status === 0) {
      console.log(c.dim(`  仓库 ${githubUser}/${repoName} 已存在，直接推送`));
      run('git', ['remote', 'remove', 'origin']);
      run('git', ['remote', 'add', 'origin',
                  `https://github.com/${githubUser}/${repoName}.git`]);
      const push = run('git', ['push', '-u', 'origin', 'main', '--force']);
      pushed = push.status === 0;
    } else {
      const create = run('gh', ['repo', 'create', `${githubUser}/${repoName}`,
                                '--public', '--source', '.', '--remote', 'origin', '--push']);
      pushed = create.status === 0;
      if (!pushed) {
        console.log(c.red('  创建仓库失败：'));
        console.log(create.stderr || create.stdout);
      }
    }
  } else {
    // 没有 gh：给出手动步骤
    console.log(c.yellow('\n  请手动完成两步：'));
    console.log('  1. 打开 https://github.com/new');
    console.log(`     仓库名填 ${c.bold(repoName)}，选 Public，不要勾选任何初始化文件`);
    console.log('  2. 创建后回到这里，执行：');
    console.log(c.dim(`     git remote add origin https://github.com/${githubUser}/${repoName}.git`));
    console.log(c.dim('     git push -u origin main'));
    console.log(c.dim('\n  推送时要求密码 → 用 Personal Access Token（不是账号密码）'));
    console.log(c.dim('  生成地址：https://github.com/settings/tokens'));
  }

  await rl.close();

  // ── 5. 结果 ──
  console.log(`\n${'─'.repeat(56)}`);
  if (pushed) {
    console.log(c.green(c.bold('  推送成功\n')));
    console.log('  下一步：');
    console.log(`  1. 打开 ${c.bold(`https://github.com/${githubUser}/${repoName}/actions`)}`);
    console.log('  2. 左侧选「Build iOS IPA」→ 右侧「Run workflow」→ 绿色按钮');
    console.log('  3. 等 5-10 分钟（macOS 机器编译比较慢，第一次要装依赖）');
    console.log('  4. 构建完成后点进那次运行，页面底部 Artifacts 下载 ipa');
    console.log('  5. 用 Sideloadly 装到 iPhone（见 INSTALL-WINDOWS.md）');
  } else {
    console.log(c.yellow('  还没推送成功，按上面的提示手动完成，或者装 GitHub CLI 后重跑本脚本。'));
  }
  console.log(`${'─'.repeat(56)}\n`);
}

main().catch((e) => {
  console.error(c.red(`\n出错了：${e.message}`));
  process.exit(1);
});
