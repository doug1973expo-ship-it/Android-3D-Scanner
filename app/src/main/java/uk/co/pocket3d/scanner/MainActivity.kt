package uk.co.pocket3d.scanner
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.google.ar.core.Config
import com.google.ar.core.Session
import uk.co.pocket3d.scanner.databinding.ActivityMainBinding
import java.io.File
import java.util.concurrent.Executors
class MainActivity:AppCompatActivity(){
 private lateinit var ui:ActivityMainBinding;private val grid=VoxelGrid();private lateinit var renderer:ScanRenderer;private var arSession:Session?=null;private val worker=Executors.newSingleThreadExecutor()
 override fun onCreate(state:Bundle?){super.onCreate(state);ui=ActivityMainBinding.inflate(layoutInflater);setContentView(ui.root);ui.surface.setEGLContextClientVersion(2);renderer=ScanRenderer(this,grid);ui.surface.setRenderer(renderer);ui.scanButton.setOnClickListener{renderer.scanning=!renderer.scanning;ui.scanButton.text=if(renderer.scanning)"Stop scan" else "Resume scan";ui.status.text=if(renderer.scanning)"Scanning — circle the object slowly" else "Scan paused"};ui.clearButton.setOnClickListener{grid.clear();updateCount(0)};ui.exportButton.setOnClickListener{export()};if(ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)startAr()else ActivityCompat.requestPermissions(this,arrayOf(Manifest.permission.CAMERA),7)}
 private fun startAr(){try{arSession=Session(this).also{s->val config=Config(s);if(s.isDepthModeSupported(Config.DepthMode.AUTOMATIC))config.depthMode=Config.DepthMode.AUTOMATIC;s.configure(config)};renderer.session=arSession;arSession?.resume()}catch(e:Throwable){Toast.makeText(this,"Google Play Services for AR is required: ${e.message}",Toast.LENGTH_LONG).show()}}
 override fun onRequestPermissionsResult(r:Int,p:Array<out String>,g:IntArray){super.onRequestPermissionsResult(r,p,g);if(r==7&&g.firstOrNull()==PackageManager.PERMISSION_GRANTED)startAr()else finish()}
 override fun onResume(){super.onResume();try{arSession?.resume()}catch(_:Throwable){};ui.surface.onResume()}
 override fun onPause(){ui.surface.onPause();arSession?.pause();super.onPause()}
 fun updateCount(n:Int){ui.count.text="$n surface cells captured";ui.exportButton.isEnabled=n>20}
 private fun export(){ui.status.text="Building STL…";ui.exportButton.isEnabled=false;worker.execute{try{val file=File(cacheDir,"exports/scan-${System.currentTimeMillis()}.stl");grid.exportStl(file);runOnUiThread{ui.status.text="STL ready";ui.exportButton.isEnabled=true;val uri=FileProvider.getUriForFile(this,"$packageName.files",file);val send=Intent(Intent.ACTION_SEND).apply{type="model/stl";putExtra(Intent.EXTRA_STREAM,uri);addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)};startActivity(Intent.createChooser(send,"Save or share STL"))}}catch(e:Throwable){runOnUiThread{Toast.makeText(this,e.message,Toast.LENGTH_LONG).show();ui.exportButton.isEnabled=true}}}}
}
