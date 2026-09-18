const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const html=fs.readFileSync(path.join(__dirname,'../codenotch/ui/notch.html'),'utf8');
const start='// CLAUDE_AUTH_ACTIONS_START', end='// CLAUDE_AUTH_ACTIONS_END';
assert.equal(html.split(start).length,2);
assert.equal(html.split(end).length,2);
const src=html.split(start)[1].split(end)[0];
const calls=[];
const ctx=vm.createContext({claudeAuth:{busy:false,message:''},claudeActionMessage:'',
  esc:s=>String(s).replaceAll('<','&lt;'), textCopy:s=>s,
  renderCard:()=>{}, invoke:async cmd=>{calls.push(cmd);return true;}});
vm.runInContext(src,ctx);
(async()=>{
  const cell=(id,status)=>({id,snap:{status}});
  assert.equal(ctx.offersClaudeSignIn(cell('claude','needsAuth')),true);
  assert.equal(ctx.offersClaudeSignIn(cell('claude','ok')),false);
  assert.equal(ctx.offersClaudeSignIn(cell('claude@work','needsAuth')),false);
  assert.match(ctx.claudeAuthHtml({busy:false,message:''}),/>Sign in</);
  assert.equal((ctx.claudeAuthHtml({busy:true,message:''}).match(/<button/g)||[]).length,1);
  assert.equal((ctx.claudeAuthHtml({busy:true,message:''}).match(/disabled/g)||[]).length,1);
  assert.ok(!ctx.claudeAuthHtml({busy:false,message:'<script>'}).includes('<script>'));
  ctx.textCopy=s=>s==='Sign in'?'Авторизоваться':s;
  assert.match(ctx.claudeAuthHtml({busy:false,message:''}),/Авторизоваться/);
  await ctx.signInClaude();
  await ctx.signInClaude();
  assert.deepEqual(calls,['claude_sign_in']);
  ctx.claudeAuth.busy=false;
  ctx.invoke=async()=>{throw new Error('fixture launch failed')};
  await ctx.signInClaude();
  assert.equal(ctx.claudeAuth.busy,false);
  assert.match(ctx.claudeActionMessage,/fixture launch failed/);
  console.log('PASS: offered only signed out on the default account, auth labels/localization, busy guard, escaping and launch errors');
})().catch(e=>{console.error(e);process.exitCode=1;});
