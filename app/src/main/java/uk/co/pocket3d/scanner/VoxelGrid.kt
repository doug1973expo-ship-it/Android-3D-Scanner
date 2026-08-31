package uk.co.pocket3d.scanner

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.floor

class VoxelGrid(private val voxel: Float = 0.006f) {
    data class Cell(val x: Int, val y: Int, val z: Int)
    private val cells = ConcurrentHashMap.newKeySet<Cell>()
    val size get() = cells.size
    fun add(x: Float, y: Float, z: Float) {
        if (x.isFinite() && y.isFinite() && z.isFinite())
            cells.add(Cell(floor(x/voxel).toInt(), floor(y/voxel).toInt(), floor(z/voxel).toInt()))
    }
    fun clear() = cells.clear()
    fun exportStl(file: File) {
        val set=cells.toHashSet()
        val dirs=arrayOf(intArrayOf(1,0,0),intArrayOf(-1,0,0),intArrayOf(0,1,0),intArrayOf(0,-1,0),intArrayOf(0,0,1),intArrayOf(0,0,-1))
        val faces=ArrayList<Pair<Cell,Int>>()
        set.forEach { c -> dirs.indices.forEach { d -> val q=dirs[d]; if(!set.contains(Cell(c.x+q[0],c.y+q[1],c.z+q[2]))) faces+=c to d } }
        file.parentFile?.mkdirs()
        BufferedOutputStream(FileOutputStream(file)).use { out ->
            out.write(ByteArray(80).also{"Pocket 3D Scanner".toByteArray().copyInto(it)})
            out.write(i32(faces.size*2))
            faces.forEach { (c,d) -> triangles(c,d).forEach { tri ->
                repeat(3){out.write(f32(0f))}
                tri.forEach { p -> p.forEach { out.write(f32(it)) } }
                out.write(byteArrayOf(0,0))
            }}
        }
    }
    private fun triangles(c:Cell,d:Int):Array<Array<FloatArray>> {
        val x=c.x*voxel*1000f; val y=c.y*voxel*1000f; val z=c.z*voxel*1000f; val s=voxel*1000f
        fun p(a:Float,b:Float,q:Float)=floatArrayOf(x+a*s,y+b*s,z+q*s)
        val v=when(d){
            0->arrayOf(p(1f,0f,0f),p(1f,1f,0f),p(1f,1f,1f),p(1f,0f,1f))
            1->arrayOf(p(0f,0f,0f),p(0f,0f,1f),p(0f,1f,1f),p(0f,1f,0f))
            2->arrayOf(p(0f,1f,0f),p(0f,1f,1f),p(1f,1f,1f),p(1f,1f,0f))
            3->arrayOf(p(0f,0f,0f),p(1f,0f,0f),p(1f,0f,1f),p(0f,0f,1f))
            4->arrayOf(p(0f,0f,1f),p(1f,0f,1f),p(1f,1f,1f),p(0f,1f,1f))
            else->arrayOf(p(0f,0f,0f),p(0f,1f,0f),p(1f,1f,0f),p(1f,0f,0f))
        }
        return arrayOf(arrayOf(v[0],v[1],v[2]),arrayOf(v[0],v[2],v[3]))
    }
    private fun i32(v:Int)=ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()
    private fun f32(v:Float)=ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(v).array()
}
