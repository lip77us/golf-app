/* Banker scorecard — net scores, because every bet in this game settles on net.
   Gold marks who banked the hole; a green box beat him. */
(function(){
var PAR=[4,4,4,3,4,4,4,5,4,4,3,4,5,3,4,4,5,4];
var SI =[1,7,3,11,9,17,5,13,15,10,6,18,2,8,12,4,16,14];
var BK =['Paul','Sam','Sam','Lee','Dave','Sam','Paul','Lee','Sam','Sam','Paul','Dave','Sam','Paul','Paul','Sam','Paul','Dave'];
/* net relative to par */
var NET={
 Paul:[0,1,0,0,1,0,0,1,1,0,1,1,0,0,1,0,1,1],
 Dave:[1,1,1,0,1,1,0,2,1,1,0,1,1,1,1,0,1,1],
 Sam :[0,0,1,0,0,1,0,1,0,1,0,0,1,-1,0,1,1,0],
 Lee :[1,2,0,1,1,0,-2,1,2,1,1,2,0,1,1,1,2,1]
};
var GETS={Paul:8,Dave:12,Sam:4,Lee:16};
var ORDER=['Paul','Dave','Sam','Lee'];
function stroke(p,i){return SI[i]<=GETS[p]?1:0}
function net(p,i){return PAR[i]+NET[p][i]}
window.BankerScorecard={
  par:PAR,si:SI,bankers:BK,net:net,stroke:stroke,
  gross:function(p,i){return net(p,i)+stroke(p,i)},
  render:function(el,opt){
    opt=opt||{};var played=opt.played!=null?opt.played:18,cw=opt.cellWidth||30;
    var css='<style>.bsc{background:#fff;border:1px solid #DCE5DD;border-radius:12px;overflow:hidden}'+
      '.bsc-h{font-family:"Schibsted Grotesk",sans-serif;font-size:12.5px;font-weight:700;padding:9px 11px 7px;display:flex;align-items:baseline}'+
      '.bsc-h em{margin-left:auto;font-style:normal;font-size:10px;font-weight:600;color:#5C6B62;letter-spacing:.3px;text-transform:uppercase}'+
      '.bsc-s{overflow-x:auto;scrollbar-width:none}.bsc-s::-webkit-scrollbar{display:none}'+
      '.bsc-t{border-collapse:separate;border-spacing:0;table-layout:fixed;font-variant-numeric:tabular-nums}'+
      '.bsc-t td{padding:0;text-align:center;font-weight:600}'+
      '.bsc-t .lb{position:sticky;left:0;z-index:2;background:#fff;text-align:left;padding:0 8px 0 10px;font-size:11.5px;font-weight:700;white-space:nowrap}'+
      '.bsc-t tr.meta .lb{background:#EEF3EF}'+
      '.bsc-t tr.meta td{background:#EEF3EF;font-size:11px;height:22px;color:#5C6B62}'+
      '.bsc-t tr.hole td,.bsc-t tr.hole .lb{background:#E1EAE2;font-weight:700;color:#0B1F1A;font-size:11px;height:24px}'+
      '.bsc-t tr.par td{font-style:italic}'+
      '.bsc-t tr.par td,.bsc-t tr.par .lb{border-bottom:1px solid #DCE5DD}'+
      '.bsc-t tr.p td{height:29px;font-size:12.5px}'+
      '.bsc-c{display:inline-flex;align-items:center;justify-content:center;width:'+(cw-4)+'px;height:23px;border-radius:5px;position:relative}'+
      '.bsc-c.bank{background:#FBF0D6;color:#8A6410;font-weight:700}'+
      '.bsc-c.beat{background:#DCF2E4;border:1px solid #7FC79F;color:#0B5B44;font-weight:700}'+
      '.bsc-c.none{color:#C3CFC6}'+
      '.bsc-d{position:absolute;top:-1px;right:-4px;width:4px;height:4px;border-radius:50%;background:#0F6E56}'+
      '.bsc-d.dim{background:#9DBDB0}'+
      '.bsc-f{display:flex;flex-wrap:wrap;align-items:center;gap:9px;padding:8px 10px 10px;font-size:10px;color:#5C6B62;border-top:1px solid #EDF2EE}'+
      '.bsc-f span{display:inline-flex;align-items:center;gap:4px}'+
      '.bsc-f s{text-decoration:none;width:11px;height:11px;border-radius:3px;display:block}'+
      '.bsc-f .g{margin-left:auto;font-weight:600}</style>';
    var cols='';for(var i=0;i<18;i++)cols+='<col style="width:'+cw+'px">';
    function r(cls,lb,fn){var o='<tr class="'+cls+'"><td class="lb">'+lb+'</td>';
      for(var i=0;i<18;i++)o+='<td>'+fn(i)+'</td>';return o+'</tr>'}
    var t='<table class="bsc-t"><colgroup><col style="width:50px">'+cols+'</colgroup>'+
      r('meta hole','Hole',function(i){return i+1})+
      r('meta par','Par',function(i){return PAR[i]})+
      ORDER.map(function(p){
        return r('p',p,function(i){
          if(i>=played)return '<span class="bsc-c none">&ndash;'+(stroke(p,i)?'<span class="bsc-d dim"></span>':'')+'</span>';
          var bank=BK[i]===p,beat=!bank&&NET[p][i]<NET[BK[i]][i],
              d=stroke(p,i)?'<span class="bsc-d"></span>':'';
          return '<span class="bsc-c'+(bank?' bank':beat?' beat':'')+'">'+net(p,i)+d+'</span>';
        });
      }).join('')+'</table>';
    el.innerHTML=css+'<div class="bsc"><div class="bsc-h">Scorecard<em>net &middot; thru '+played+'</em></div>'+
      '<div class="bsc-s">'+t+'</div>'+
      '<div class="bsc-f"><span><s style="background:#FBF0D6"></s>banked</span>'+
      '<span><s style="background:#DCF2E4;border:1px solid #7FC79F"></s>beat the banker</span>'+
      '<span><span class="bsc-d" style="position:static"></span>stroke</span>'+
      '<span><span class="bsc-d dim" style="position:static"></span>stroke to come</span>'+
      '<span class="g">everything else lost or tied him</span></div></div>';
  }
};
})();
